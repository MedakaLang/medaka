# META
source_lines=3301
stages=DESUGAR,MARK
# SOURCE
-- compiler/medaka_cli.mdk — the native `medaka` CLI dispatcher (Phase C
-- Slice 0+1).  Compiled natively (`medaka build compiler/medaka_cli.mdk -o
-- ./medaka`) this is a Medaka CLI replacing bin/main.ml's check/fmt/new
-- subcommands with no OCaml at runtime.
--
--   ./medaka check <file.mdk>     type-check (parse→…→typecheck), via check.runCheck
--   ./medaka fmt [--stdout|--check|--write] <file.mdk>   format (default: --check, read-only; --write rewrites)
--   ./medaka new <name>           scaffold a new project
--   ./medaka help | --help | -h   usage
--
-- Stdlib paths (runtime.mdk / core.mdk) resolve from MEDAKA_ROOT, mirroring
-- compiler/build_cmd.mdk's envOr — compiler has no getcwd/executable_name
-- extern.  The implemented subcommands are exactly the dispatch arms below
-- (check/fmt/new/build/run/test/repl/lsp/doc/check-policy/manifest/gate); any other
-- subcommand falls through to the catch-all, which prints "not yet in native
-- CLI" and exits 1.

import tools.check.{runCheck, checkHasErrors, runCheckModules}
import tools.snapshot.{
  runSnapshotWorker,
  runSnapshotSupervisor,
  parseStages,
  SnapMode(..),
}
import tools.fmt.{formatSource}
import tools.gate_cmd.{gateHelpText, runGateCmd}
import tools.new_cmd.{newProject}
import driver.build_cmd.{
  BuildResult,
  BuildOk,
  BuildErr,
  BuildTarget,
  TNative,
  TWasm,
  runBuild,
  emitRtObj,
  emitPreludeObj,
  envOr,
  defaultMedakaRoot,
  readPreludeFile,
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
  schemeLineName,
  stringTrim,
}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omFromNames}
import support.path.{baseOf, chopExt, joinPath}
import support.timer.{perfEnabled, now, emitPhase, emitTotal}
import frontend.ast.{Decl(..), Expr(..), Loc(..), Pat, LetBind(..)}
import frontend.parser.{
  parse,
  parseLocated,
  parseWithPositions,
  parseWithPositionsLocated,
  parseResult,
  ParseError,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
  Positions,
}
import frontend.desugar.{desugar}
import frontend.resolve.{resolveModulesToHumaneByPath}
import driver.loader.{
  LoadError,
  LoadMsg,
  LoadParseFailed,
  loadProgramFilesLocatedE,
  findProjectRoot,
  findProjectRootOrSelf,
  entrySearchRoots,
  projectTrustedMods,
  stdlibOwnership,
  unknownModuleIdOf,
  findImportLoc,
  availableModulesHint,
  availableModulesText,
}
import driver.diagnostics.{
  analyzeProject,
  analyzeLocated,
  analyzeLocatedG,
  ppDiagCli,
  ppDiagCliSrc,
  ppDiagCliLines,
  srcLinesArr,
  Diag(..),
  Severity(..),
  SevError,
  cjPosition,
  cjRange,
  cjRangeOfLoc,
  cjDiagnostic,
  cjFileEntry,
  cjAllToJson,
  readDiagSrc,
  parseErrCode,
  parseErrHelpFix,
  codeKind,
  optField,
  cjFixJson,
  mkDiag,
  checkJsonFile,
  readFileSafe,
  diagIsError,
  findMainFunDef,
  mainBodyLoc,
  mainArityMsg,
  mainNonUnitMsg,
  mainArityWarning,
  mainNonUnitWarning,
  mainShapeWarnings,
}
import json.{
  Json,
  JInt,
  JString,
  JArray,
  JObject,
  JNull,
  jObject,
  jArray,
  stringify,
}
import types.typecheck.{
  elaborateModules,
  resetTypeErrorsSticky,
  hadTypeErrors,
  mainTypeIsAsync,
  mainTypeIsUnit,
  setStdlibOwnership,
}
import eval.eval.{
  evalModulesOutputRun,
  evalModulesOutputAsync,
  currentEvalFile,
  modulePathMap,
  runJsonMode,
  pendingRunDiags,
  progArgsRef,
}
import tools.test_cmd.{runTest}
import tools.doctest.{Engine(..)}
import tools.repl.{initSession, replLoop}
import tools.lsp.{runServer}
import tools.mcp.{runMcpServer}
import tools.doc.{runDoc}
import tools.lint.{
  allRules,
  lintProgram,
  applySuppressions,
  applySuppressionsMulti,
  applySuppressionsDirs,
  applySuppressionsMultiDirs,
  collectDirectives,
  findingToDiag,
  Finding,
  Directive,
  applyFixes,
  runCrossFileRules,
  runCrossFileRulesFromOccs,
  crossFileCacheSound,
  fileDupOccs,
  parseLintFlagList,
  applyFindingFilters,
  applyFindingDeny,
  isFindingError,
  lintFileDiagTriple,
  splitLintNames,
}
import tools.lint_cache.{
  LintEntry(..),
  contentHashOf,
  ruleSetStamp,
  cacheDirOf,
  loadEntry,
  storeEntries,
}
import tools.codemod.{
  findCodemod,
  codemodMk,
  codemodWarnDecls,
  codemodListing,
  codemodSource,
}
import tools.check_policy.{
  runCheckPolicy,
  PolicyArgs(..),
  parsePolicyArgs,
  PolicyOutcome(..),
  runManifest,
  parseManifestArgs,
  ManifestArgs(..),
}

-- FLAG for user confirmation: exact version string/format not yet confirmed —
-- using "0.1.0-preview" (the 0.1.0 public-preview target named in AGENTS.md)
-- pending sign-off. No existing version constant was found elsewhere in
-- compiler/ (lsp.mdk hardcodes a literal "0.1.0" for its own protocol reply;
-- new_cmd.mdk hardcodes a literal "0.1.0" into scaffolded medaka.toml — neither
-- is a shared constant this could reuse).
medakaVersion : String
medakaVersion = "0.1.0-preview"

printVersion : Unit -> <IO> Unit
printVersion _ = putStrLn ("medaka " ++ medakaVersion)

-- ── staleness guard (issue #89) ─────────────────────────────────────────────
-- A ./medaka built in tree Y but run against tree X's NEWER compiler sources
-- silently applies OLD compiler semantics (an old binary misreads `1.5e3` as
-- `Unbound variable: e3`), and the version string ("0.1.0-preview") never moves,
-- so it is useless as a staleness signal.  test/build_native_medaka.sh bakes the
-- compiler-source fingerprint into the binary (-DMEDAKA_SRC_FP, surfaced by the
-- `buildFingerprint` extern); here we recompute the SAME fingerprint over the
-- LIVE <root>/compiler and warn on a mismatch.  MEDAKA_STRICT=1 promotes the
-- warning to a hard error.  Runs on every invocation, so it is gated TIGHTLY:
-- only when a stamp was baked AND <root>/compiler is present (a shipped binary
-- has neither).
--
-- `liveSourceFingerprint` reproduces src_fingerprint() from the build script
-- byte-for-byte: names AND contents of `find compiler -name '*.mdk' | LC_ALL=C
-- sort`, hashed by the same hash_stream chain (sha256sum → shasum → cksum).  The
-- per-file `while read; cat` shell loop the script uses costs ~110ms (118 forks);
-- we stream through ONE perl process (~16ms, verified byte-identical).  perl
-- absent → the guard exits non-zero → None → the check silently skips (never a
-- false warning).
liveSourceFingerprint : String -> <IO> Option String
liveSourceFingerprint root =
  let script = stringConcat [
    "command -v perl >/dev/null 2>&1 || exit 7; cd \"",
    root,
    "\" && find compiler -name '*.mdk' -print | LC_ALL=C sort",
    " | perl -ne 'chomp; print \"$_\\n\"; open F,\"<\",$_ or next; local $/; my $c=<F>; print $c if defined $c; close F' 2>/dev/null",
    " | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif command -v shasum >/dev/null 2>&1; then shasum -a 256; else cksum; fi; }",
    " | cut -d' ' -f1",
  ]
  match runCommand "sh" ["-c", script]
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
  if baked == "" then None
  else
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let compilerDir = joinPath root "compiler"
    if not (fileExists compilerDir) then None
    else match liveSourceFingerprint root
      None => None
      Some live => if live == baked then None else Some compilerDir

checkSourceStaleness : Unit -> <IO> Unit
checkSourceStaleness _ = match sourceStalenessVerdict ()
  None => ()
  Some compilerDir =>
    let msg = "warning: this ./medaka was built from compiler source that differs from " ++ compilerDir ++ " — it may be stale; rebuild with 'make medaka'."
    if envOr "MEDAKA_STRICT" "" /= "" then
      let _ = ePutStrLn msg
      exit 1
    else ePutStrLn msg

main : <IO> Unit
main =
  let _ = checkSourceStaleness ()
  runCli ()

runCli : Unit -> <IO> Unit
runCli _ = match args ()
  [] => usage ()
  "help"::_ => usage ()
  "--help"::_ => usage ()
  "-h"::_ => usage ()
  "--version"::_ => printVersion ()
  "-v"::_ => printVersion ()
  "version"::_ => printVersion ()
  "check"::rest => dispatchSub checkHelpText runCheckCmd rest
  "fmt"::rest => dispatchSub fmtHelpText runFmtCmd rest
  "new"::rest => runNewCmd rest
  "build"::rest => runBuildCmd rest
  "run"::rest => dispatchSub runHelpText runRunCmd rest
  "test"::rest => dispatchSub testHelpText runTestCmd rest
  "snapshot"::rest => dispatchSub snapshotHelpText runSnapshotCmd rest
  "doc"::rest => dispatchSub docHelpText runDocCmd rest
  "lint"::rest => dispatchSub lintHelpText runLintCmd rest
  "codemod"::rest => dispatchSub codemodHelpText runCodemodCmd rest
  "check-policy"::rest => dispatchSub checkPolicyHelpText runCheckPolicyCmd rest
  "manifest"::rest => dispatchSub manifestHelpText runManifestCmd rest
  "gate"::rest => dispatchSub gateHelpText runGateCmd rest
  "repl"::rest => runReplCmd rest
  "lsp"::rest => runLspCmd rest
  "mcp"::rest => runMcpCmd rest
  sub::_ => notYet sub

-- #1348: `medaka <sub> --help`/`-h` used to fall straight into the
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
dispatchSub help _ ("--help"::_) =
  let _ = putStrLn help
  exit 0
dispatchSub help _ ("-h"::_) =
  let _ = putStrLn help
  exit 0
dispatchSub _ run rest = run rest

-- ── usage (mirrors bin/main.ml print_usage) ───────────────────────────────
-- Takes Unit so the interpreter's top-level-value evaluation doesn't fire its
-- IO eagerly (native build only runs main); native CLI prints it on demand.
usage : Unit -> <IO> Unit
usage _ = putStrLn (stringConcat
  [
    "medaka. A functional language compiler\n",
    "\n",
    "Usage:\n",
    "  medaka                    Show this message\n",
    "  medaka run [--release] <file.mdk>   Type-check and run a program\n",
    "  medaka build <file.mdk> [-o <out>] [--keep-ir]  Compile to a native binary (LLVM + clang)\n",
    "  medaka check [--json] <file.mdk>    Type-check without running\n",
    "  medaka test [--native | --engines eval,native] [file.mdk]    Run doctests + prop tests (--native runs doctests through a compiled native binary INSTEAD of the interpreter; --engines runs the listed set, exit is the AND)\n",
    "  medaka doc [file.mdk]     Generate Markdown documentation\n",
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
    "  medaka help               Show this message\n",
    "  medaka --version          Show the compiler version\n",
  ])

-- ── deferred subcommands ──────────────────────────────────────────────────
notYet : String -> <IO> Unit
notYet sub =
  let _ = ePutStrLn ("medaka: subcommand '" ++ sub ++ "' not yet in native CLI")
  exit 1

-- ── check ─────────────────────────────────────────────────────────────────
-- PARSE-ERROR-LOCATION Stage 1: render a located `ParseError` through the SAME
-- caret-aware `ppDiagCliSrc` + `Diag` machinery the typecheck/resolve text paths
-- use, so EVERY CLI-text parse error gets `file:L:C:` + a source snippet + caret
-- + the stable `P-*`/`L-*` code (and, for the clean single-token hints, a `help`).
-- `parseErrorLine` is 1-based, `parseErrorCol` 0-based — the exact convention
-- `ppDiagCliSrc`/`parseErrHelpFix` expect (matching the `--json` inline build).
ppParseError : String -> String -> ParseError -> String
ppParseError src file e =
  let ploc = Loc file (parseErrorLine e) (parseErrorCol e) (parseErrorLine e) (parseErrorCol e + 1)
  let (h, fx) = parseErrHelpFix (parseErrorMessage e) ploc
  ppDiagCliSrc
    src
    file
    (Diag
      SevError
      (parseErrCode (parseErrorMessage e))
      (parseErrorMessage e)
      (Some ploc)
      h
      fx)

-- Reads <MEDAKA_ROOT>/stdlib/{runtime,core}.mdk + the target, runs
-- check.runCheck, prints schemes/diagnostics.  Mirrors check_main.mdk; exit 0
-- (runCheck reports diagnostics in-band, like the interpreted driver).
--
-- DRIVER-COLLAPSE Phase 4 (OPTION A): `check` now RESOLVES imports.  We load the
-- entry + its transitive imports via loadProgram (same roots/priority as run/build)
-- and route by module count: a 1-module load (no non-core imports) goes through the
-- single-file runCheck (full prelude+user scheme dump, byte-identical to the old
-- behaviour — keeps the no-import goldens green); a multi-module load goes through
-- runCheckModules (multi-module resolve + per-module-frame typecheck), so a valid
-- cross-module reference reports import-aware diagnostics instead of `UnknownModule`.
checkHelpText : String
checkHelpText = stringConcat
  [
    "medaka check — Type-check a file without running it\n",
    "\n",
    "Usage:\n",
    "  medaka check [--json] [--types] [--allow-internal] <file.mdk>\n",
    "\n",
    "  --json            emit the {\"files\":[...]} structured-diagnostics\n",
    "                    envelope instead of human text\n",
    "  --types           show the full inferred-scheme dump, prelude included\n",
    "                    (default: only your own top-level bindings)\n",
    "  --allow-internal  permit internal-only externs outside stdlib/\n",
  ]

runCheckCmd : List String -> <IO> Unit
runCheckCmd argv =
  let perfOn = perfEnabled ()
  let perfT0 = now ()
  let jsonMode = hasFlag "--json" argv
  let allowInternal = hasFlag "--allow-internal" argv
  let typesMode = hasFlag "--types" argv
  let argv2 = dropFlags argv
  match argv2
    [target] =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let rtPath = root ++ "/stdlib/runtime.mdk"
      let corePath = root ++ "/stdlib/core.mdk"
      let stdlibDir = root ++ "/stdlib"
      let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
      match readPreludeFile rtPath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok rsrc => match readPreludeFile corePath
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          Ok csrc => if jsonMode then runCheckJsonCmd allowInternal rsrc csrc target stdlibDir
          else match readFile target
            Err msg =>
              let _ = ePutStrLn msg
              exit 1
            Ok tsrc => match parseResult tsrc
              Err e =>
                let _ = ePutStrLn (ppParseError tsrc target e)
                exit 1
              -- Load with parseLocated (real ELoc spans), mirroring `run`
              -- (line ~678): plain loadProgram uses placeholder-loc `parse`,
              -- which collapses every span to 1:0, so an import-bearing
              -- file's Unbound-variable diagnostic pointed at the import
              -- line instead of the actual use site.
              Ok _ => match loadProgramFilesLocatedE (_ => None) target roots
                Err lerr =>
                  let _ = ePutStrLn (moduleLoadErrText tsrc target stdlibDir lerr)
                  exit 1
                Ok modsWithPath =>
                  let mods = map dropModPath modsWithPath
                  let pathMap = map modIdToPath modsWithPath
                  let trusted = projectTrustedMods target roots stdlibDir mods
                  -- #2072: the FFI-stamp discriminator, published to typecheck alongside the
                  -- #1713 reference-trust set above.  DIFFERENT predicate, deliberately: this
                  -- one is stdlib-root ownership with NO `allow-internal` opt-out.
                  let (flatStdlib, ownedStdlib) = stdlibOwnership target roots stdlibDir mods
                  let _ = setStdlibOwnership flatStdlib ownedStdlib
                  let perfTLoad = now ()
                  let _ = emitPhase perfOn "load" (perfTLoad - perfT0) target
                  let _ = checkRoute typesMode allowInternal trusted pathMap roots rsrc csrc tsrc target mods
                  let perfTCheck = now ()
                  let _ = emitPhase perfOn "check" (perfTCheck - perfTLoad) target
                  emitTotal perfOn (perfTCheck - perfT0)
    _ =>
      let _ = ePutStrLn "usage: medaka check [--json] [--types] [--allow-internal] <file.mdk>"
      exit 1
-- G1: print the report (byte-identical stdout for no-import files:
-- diff_native_cli gate), then gate the EXIT CODE on the error predicate
-- so CI `$?` matches OCaml `check` (exit 1 on any error).

-- A load error (missing/cyclic import) is reported verbatim, like
-- build/run; exit 1.  No-fixture single-file files never error here.

-- F3 Chunk B (R-MODULE-LOAD): the loader's `Err "unknown module: X"` carries no
-- location (see loader.mdk's entry-scan doc comment).  `tsrc` is already known
-- to parse (the caller's `parseResult` succeeded), so re-parse it with
-- `parseLocated` (real ELoc/DUse spans) and look up the failing modId's own
-- `import` statement; render through the shared carat formatter when found,
-- else fall back to the bare message (unchanged behaviour).
-- F: an `unknown module` message additionally carries an "available modules:
-- ..." suffix (enumerated from `roots` via loader's `availableModulesHint`) so
-- the CLI-text path — which does not render structured `help` — still surfaces
-- an actionable fix.  Other loader errors (cycle / unreadable file) are
-- unaffected: `unknownModuleIdOf` gates the hint to the one message shape it
-- applies to.
-- A parse/lex error inside an IMPORTED module (#100) renders exactly as though
-- that module had been checked directly: `ppParseError` against the module's OWN
-- source and path, so the file, line/col, caret and `P-*`/`L-*` code all name the
-- module that is actually broken rather than the entry that imported it.
moduleLoadErrText : String -> String -> String -> LoadError -> <IO> String
moduleLoadErrText _ _ _ (LoadParseFailed mpath msrc e) =
  ppParseError msrc mpath e
moduleLoadErrText tsrc target stdlibDir (LoadMsg lmsg) = match unknownModuleIdOf lmsg
  None => lmsg
  Some mid =>
    let msg = lmsg ++ availableModulesHint stdlibDir
    match findImportLoc mid (parseLocated tsrc)
      None => msg
      Some loc => ppDiagCliSrc tsrc target (Diag SevError "R-MODULE-LOAD" msg (Some loc) None None)

-- Render every ERROR diagnostic across a loaded multi-module project as located
-- human text (`file:L:C: msg` + caret), reusing the SAME `analyzeProject` the
-- `--json` path uses (line ~549).  This is what lets `check`/`run`/`build`
-- surface an IMPORTED-module type error WITH its location — not just the entry
-- module, and not the loc-free `TYPE ERROR: …`/boolean-deflection they used to
-- collapse to.  `None` when the project has no error diagnostics (clean).
-- Dependency-first file order (helper before entry), same as the loader/JSON.
locatedProjectErrors : Bool -> List String -> String -> List String -> String -> String -> <IO> Option String
locatedProjectErrors allowInternal trusted target roots rsrc csrc =
  errTextOf (locatedProjectDiags allowInternal trusted target roots rsrc csrc)

errTextOf : (Option String, List (String, String, List Diag), Int) -> Option String
errTextOf (errText, _, _) = errText

-- BOTH halves of the project analysis from ONE `analyzeProject` pass: the rendered
-- errors (exactly what `locatedProjectErrors` returns) AND the COHERENCE warnings.
--
-- Why one pass.  `run`/`build`'s multi-module arms already call this analysis as
-- their check-strength gate and then THREW THE WARNINGS AWAY — so after F-3d demoted
-- the coherence reject onto the warning channel, a program those verbs used to
-- reject compiled and ran with nothing on any channel.  A second entry point would
-- mean a second whole-front-end pass over the whole graph, which is the dominant
-- cost of the gate; splitting one pass's result costs a list filter.
--
-- 🚨 THE SECOND COMPONENT IS UNRENDERED, AND THAT IS LOAD-BEARING, NOT STYLE.
-- Medaka is STRICT, so `fst`-only callers — every `medaka check` of a multi-module
-- project — evaluate it too.  An earlier revision returned RENDERED warning lines
-- for the whole channel here, and multi-module `check` went 16.0–17.1 s → 38.9–40.6 s
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
-- #1362: `allowInternal`/`trusted` gate the internal-extern guard on the
-- resolve half of this pass, exactly like the `resolveModulesToHumaneByPath`
-- gate every caller here already runs BEFORE this one — this call is
-- redundant-but-consistent (a resolve error this pass could newly find would
-- already have been caught upstream), not a second independent gate.
locatedProjectDiags : Bool -> List String -> String -> List String -> String -> String -> <IO> (Option String, List (String, String, List Diag), Int)
locatedProjectDiags allowInternal trusted target roots rsrc csrc =
  let cacheRef = Ref []
  let parseCacheRef = Ref []
  let results = analyzeProject allowInternal trusted cacheRef parseCacheRef (_ => None) target roots rsrc csrc
  let triples = map readDiagSrc results
  (
    joinedOrNone (flatMap renderTripleErrors triples),
    map cohWarnsOfTriple triples,
    length (flatMap hiddenWarnsOfTriple (dropEntryTriple triples)),
  )

cohWarnsOfTriple : (String, String, List Diag) -> (String, String, List Diag)
cohWarnsOfTriple (path, src, diags) = (path, src, filter isCoherenceWarn diags)

-- the warn diagnostics on one (non-entry) module's triple that neither
-- channel above already surfaces (see the doc comment on `locatedProjectDiags`).
hiddenWarnsOfTriple : (String, String, List Diag) -> List Diag
hiddenWarnsOfTriple (_, _, diags) = filter isHiddenNonEntryWarn diags

isHiddenNonEntryWarn : Diag -> Bool
isHiddenNonEntryWarn d = isDiagWarn d && not (isCoherenceWarn d)

joinedOrNone : List String -> Option String
joinedOrNone [] = None
joinedOrNone ls = Some (joinNl ls)

-- #2044: split the source ONCE, not once per diagnostic — and, per the strictness
-- trap the 🚨 note on `locatedProjectDiags` above already spells out, not at all
-- when there is nothing to render.  `map f xs` with `f = ppDiagCliLines
-- (srcLinesArr src) path` builds that partial application from ALREADY-EVALUATED
-- arguments, so a strict language splits the whole file before `map` ever looks at
-- whether `xs` is empty — which made a clean multi-module project pay a full
-- per-file `Array String` split on EVERY file for output that does not exist.
-- The `[]` arm is what keeps the split off the zero-diagnostic path; keep it.
renderTripleErrors : (String, String, List Diag) -> List String
renderTripleErrors (path, src, diags) =
  let errs = filter isDiagError diags
  match errs
    [] => []
    _ => map (ppDiagCliLines (srcLinesArr src) path) errs

renderTripleWarnings : (String, String, List Diag) -> List String
renderTripleWarnings (path, src, diags) =
  let ws = filter isDiagWarn diags
  match ws
    [] => []
    _ => map (ppDiagCliLines (srcLinesArr src) path) ws

-- For the run/build multi-module gates, whose SOUNDNESS predicate stays the
-- looser `hadTypeErrors` (checkModulesHasErrors over-rejects valid code — see
-- typecheckGateRoute's note): once that gate has already fired, render the located
-- per-module diagnostics for the human message, falling back to the generic
-- deflection only if analyzeProject surfaces none (never leaves the user with
-- exit 1 and no text).
--
-- 🚨 #1813: the None arm must NOT send the user to `medaka check`.  This arm fires
-- EXACTLY when `analyzeProject` (check's own predicate) surfaced nothing while the
-- elaborate pass armed `hadTypeErrors` — i.e. precisely the #1812 divergence, where
-- `medaka check` on this program exits 0 and reports success.  The old text read
-- "Run `medaka check` for details" and so named the one command guaranteed to
-- confirm the wrong thing.  The elaborate pass's own diagnostic text is NOT
-- reachable here (`elaborateModules` returns decls, not diags, and the sticky
-- accumulator `hadTypeErrors` reads is a Bool), so the arm still cannot print the
-- real error — but it now says WHERE the error was detected and warns that `check`
-- may not show it, instead of promising detail that command will not deliver.
locatedOrGeneric : Bool -> List String -> String -> List String -> String -> String -> <IO> String
locatedOrGeneric allowInternal trusted target roots rsrc csrc = match locatedProjectErrors allowInternal trusted target roots rsrc csrc
  Some t => t
  None => "error: type error in "
    ++ target
    ++ ", detected during elaboration (the run/build type pass); no located"
    ++ " diagnostic is available for it, and `medaka check` may not report this"
    ++ " program at all — see issue #1812"

-- Route by module count: a single loaded module (no non-core imports) ⇒ the
-- single-file runCheck (byte-identical full dump); >1 module ⇒ the multi-module
-- import-resolving report.  `mods` is dependency-first, entry last.
-- `target` is passed for positioned error output (Stage-A: file:line:col: message).
--
-- 0.1.0 preview UX (audit #6): bare `medaka check` on a clean single-file
-- program used to dump the ~120-line prelude `=== TYPES ===` scheme corpus
-- ahead of the user's own bindings — noisy and beginner-unfriendly. `typesMode`
-- (the `--types` flag) opts back into that full dump, byte-identical to the
-- historical behaviour (preserves the diff_native_cli goldens, which now pass
-- `--types`). Bare `check` instead keeps only the lines naming one of the
-- user's OWN top-level bindings (`userSchemeLines`) — filtering happens HERE,
-- CLI-only, so the probe-driven goldens (check_main.mdk et al., which call
-- `runCheck`/`runCheckModules` directly) keep dumping unconditionally.
checkRoute : Bool -> Bool -> List String -> List (String, String) -> List String -> String -> String -> String -> String -> List (String, List Decl) -> <IO> Unit
checkRoute typesMode allowInternal trusted _ _ rsrc csrc tsrc target [(mid, decls)] =
  -- BUGFIX (internal-extern noise on stdlib/compiler self-checks): the caller
  -- already computed `trusted` (projectTrustedMods, owning-root based) for
  -- EVERY module count, but this single-module arm used to discard it and
  -- gate purely on the CLI `--allow-internal` flag — so `medaka check` on a
  -- bare stdlib file (e.g. `stdlib/array.mdk`, no non-core imports ⇒ this
  -- arm) flagged its OWN legitimate internal-extern calls as errors unless
  -- the flag was passed every time, even with MEDAKA_ROOT correctly set.
  -- Honour `trusted` here too, matching the multi-module arm below.
  let diags = analyzeLocatedG mid (allowInternal || contains mid trusted) rsrc csrc tsrc
  let errs = filter isDiagError diags
  match errs
    [] =>
      -- Clean (no errors): the scheme dump goes to STDOUT loc-free, but any
      -- non-exhaustive-match WARNING is re-rendered LOCATED (file:L:C: + caret)
      -- to STDERR, byte-consistent with how errors render (line ~277).  runCheck
      -- bundles the warning loc-free into stdout, so we strip its "Warning: …"
      -- lines and re-emit them from `diags` (which carries the real Loc the
      -- --json path already reports).  See ERROR-QUALITY.md (Located dimension).
      let warns = filter isDiagWarn diags
      let dump = stripWarningLines (runCheck rsrc csrc tsrc)
      let filtered = userSchemeLines decls dump
      let report = if typesMode then dump else filtered
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
      -- 0.1.0 beginner-footgun warning (main-shape, see below): reuse the same
      -- elaborateModules the multi-module route calls just for mainSchemeRef —
      -- runCheck's own single-file path never populates it.
      let mainWarns = mainShapeWarnings (desugar (parse rsrc)) (desugar (parse csrc)) [(mid, desugar decls)] decls
      let _ = emitLocatedWarnings tsrc target (warns ++ mainWarns)
      ()
    _ =>
      let _ = ePutStrLn (joinNl (map (ppDiagCliLines (srcLinesArr tsrc) target) errs))
      exit 1
checkRoute typesMode allowInternal trusted pathMap roots rsrc csrc tsrc target mods =
  let rtD = desugar (parse rsrc)
  let coreD = desugar (parse csrc)
  let modsD = map desugarPair mods
  -- RESOLVE-phase errors (e.g. importing a name a module does not export —
  -- PrivateNameAccess) go to STDERR + exit 1, mirroring the single-file arm's
  -- channel discipline (errors→stderr).  Previously these were `putStr` to STDOUT
  -- unprefixed, so they were invisible to any errors-on-stderr consumer (the
  -- error-quality corpus captured them as empty).  The clean/type-error report
  -- still goes to STDOUT (the check_cli_modules gate expects TYPE ERROR there).
  -- #41: attribute each module's resolve errors to its OWN file (via `pathMap`),
  -- not a single `target` fallback that mislabels every imported-module error as
  -- the entry file.
  let resDiags = resolveModulesToHumaneByPath pathMap allowInternal trusted rtD coreD modsD
  match resDiags
    "" =>
      -- BUGFIX (imported-module diagnostics): when there ARE type errors, render
      -- the accumulated per-module diagnostics LOCATED (`file:L:C: msg` + caret),
      -- across ALL modules — reusing the exact analyzeProject surface `--json`
      -- mirrors — instead of runCheckModules's loc-free `TYPE ERROR: …` (which
      -- also dropped every imported-module error's location).  Clean ⇒ the schemes
      -- dump + main-shape warnings, unchanged.
      -- `locatedProjectDiags`, not `locatedProjectErrors`: the SAME single
      -- `analyzeProject` pass, keeping the coherence warnings its `fst` discards.
      match locatedProjectDiags allowInternal trusted target roots rsrc csrc
        (Some errText, _, _) =>
          let _ = putStr errText
          exit 1
        (None, projWarns, hiddenCount) =>
          let _ = putStrLn (runCheckModules allowInternal trusted rtD coreD modsD)
          -- F-3d: an IMPORTED module's ⊑-incomparable pair, LOCATED against that
          -- module's own file.  The line above reaches the ENTRY's diagnostics only,
          -- which is why the entry triple is special-cased here (not the whole list)
          -- — see `trimEntryTriple` for the four graph positions this was silent in,
          -- and for why the entry is TRIMMED BY CODE rather than dropped whole.
          let _ = emitWarningLines (flatMap renderTripleWarnings (trimEntryTriple projWarns))
          -- #1719: a non-entry module can carry OTHER warnings (chiefly
          -- non-exhaustive-match) that the line above does not surface — human
          -- `check` used to just drop these with no trace, reading as a clean
          -- bill of health.  Say so instead of staying silent; `--json` already
          -- reports them per-file.
          let _ = emitHiddenDiagNote hiddenCount
          -- 0.1.0 main-shape warning (see below): runCheckModules/
          -- checkModulesHasErrors never call elaborateModules, so mainSchemeRef
          -- is never populated on this route either — mainShapeWarnings runs
          -- it itself (only when the cheap syntactic arity check finds nothing).
          let mainWarns = match lastModPair mods
            Some (emid, edecls) => mainShapeWarnings rtD coreD modsD edecls
            None => []
          emitLocatedWarnings tsrc target mainWarns
    _ =>
      let _ = ePutStrLn resDiags
      exit 1

-- ── main-shape beginner-footgun warning (0.1.0 audit #3; #1236) ─────────────
-- `medaka run` evaluates top-level bindings and checks `main` EXISTS but never
-- APPLIES it: a `main` that isn't a zero-arg Unit-typed value silently no-ops
-- (exit 0, no output, no diagnostic).  Both beginner shapes (`main () = …` /
-- `main x = …`, and a zero-arg non-Unit/non-Async VALUE main) render as an
-- ordinary LOCATED `W-MAIN-SHAPE` Diag now — the SAME `Diag` type every other
-- diagnostic uses, so the human CLI (`ppDiagCliSrc`/`emitLocatedWarnings`),
-- `check --json`, and `run --json` all render/serialize it uniformly.  #1236:
-- `findMainFunDef`/`mainBodyLoc`/`mainArityMsg`/`mainNonUnitMsg`/
-- `mainArityWarning`/`mainNonUnitWarning`/`mainShapeWarnings` moved to
-- `driver.diagnostics` so `checkJsonSingle`/`checkJsonFile` can fold this into
-- the SAME `{"files":[...]}` envelope `check --json` already builds instead of
-- each CLI surface keeping its own copy of the message.

-- Last (String, List Decl) pair — the entry module (loader's `mods` is
-- dependency-first, entry last).
lastModPair : List (String, List Decl) -> Option (String, List Decl)
lastModPair [] = None
lastModPair [p] = Some p
lastModPair (_::rest) = lastModPair rest

-- Drop check's non-positional flags (--release is silently ignored; --json is
-- handled by the caller via hasFlag before dropFlags strips it). `medaka
-- test`'s own flags (--native, --engines <list>) are NOT here — `--engines`
-- takes a value dropFlags doesn't know how to skip, so `medaka test` filters
-- its own argv via `testTargets` instead (below).
dropFlags : List String -> List String
dropFlags [] = []
dropFlags ("--json"::rest) = dropFlags rest
dropFlags ("--release"::rest) = dropFlags rest
dropFlags ("--allow-internal"::rest) = dropFlags rest
dropFlags ("--types"::rest) = dropFlags rest
dropFlags (x::rest) = x :: dropFlags rest

-- True if the flag appears anywhere in argv.
hasFlag : String -> List String -> Bool
hasFlag _ [] = False
hasFlag flag (x::rest)
  | x == flag = True
  | otherwise = hasFlag flag rest

-- ── check --json ───────────────────────────────────────────────────────────
-- Mirrors OCaml's `check --json` (bin/main.ml line ~863):
--   analyze_project → all_diagnostics_to_json → print_endline → exit
-- Key ordering matches OCaml/Yojson alphabetical insertion:
--   file entry:   file, diagnostics
--   diagnostic:   message, range, severity, source
--   range:        end, start
--   position:     character, line

-- Run check --json: mirrors OCaml's check --json (analyze_project → JSON).
-- Routes by module count (mirrors checkRoute) because the compiler analyzeProject
-- multi-module path has a known limitation for single-file type errors:
--   single module (no non-core imports) → analyzeLocated (single-file path)
--   multi-module → analyzeProject (loader path)
-- The ENTRY's parse errors are detected FIRST via parseResult; an IMPORTED
-- module's are reported by the loader itself (#100), attributed to that module.
-- Output: {"files":[{"file":<path>,"diagnostics":[...]}]}
-- Exits 1 if any error diagnostic; 0 otherwise.
-- The whole routing (parse-error / load-error / single / multi module) now lives
-- in `checkJsonFile` (driver.diagnostics), shared with the `medaka mcp`
-- medaka_check tool.  This driver just prints the JSON and gates the exit code —
-- stdout is byte-identical to the old inline body (diff_native_cli golden).
-- #333: `target` is `readFile`'d FIRST (mirrors `medaka_check`'s MCP handler,
-- `runCheckTool` in tools/mcp.mdk) so a nonexistent/unreadable path reports a
-- file-not-found diagnostic instead of falling into `checkJsonFile`'s import
-- loader, which otherwise misreports it as an unknown-module R-MODULE-LOAD
-- diagnostic (`checkJsonFile` reads the path itself via `readFileSafe`, which
-- swallows the error as `""`). This guard only validates readability; the
-- content it reads is discarded and `checkJsonFile` re-reads `target` for the
-- real run with full import resolution.
runCheckJsonCmd : Bool -> String -> String -> String -> String -> <IO> Unit
runCheckJsonCmd allowInternal rsrc csrc target stdlibDir = match readFile target
  Err e =>
    let _ = println (cjFileNotFoundJson target e)
    exit 1
  Ok _ =>
    let (json, hasErr) = checkJsonFile allowInternal rsrc csrc target stdlibDir
    let _ = println json
    if hasErr then exit 1 else ()

-- #1078: `medaka build --json`'s envelope for a build-STAGE failure — the
-- emitter/clang step itself, AFTER the front-end gate (checkJsonFile, reused
-- unchanged) has already passed. Same `{"files":[...]}` shape as every other
-- `--json` path (`cjAllToJson`), one span-less `Diag` carrying the emitter's
-- own message verbatim, so a caller keying off `code` (AGENTS.md) can
-- distinguish this from a front-end R-*/T-* diagnostic. Registered in
-- compiler/DIAGNOSTIC-CODES-DESIGN.md.
cjBuildFailedJson : String -> String -> String
cjBuildFailedJson target msg = cjAllToJson
  [(target, "", [Diag SevError "R-BUILD-FAILED" msg None None None])]

-- `medaka build --json`: front-end gate via `checkJsonFile` (BYTE-IDENTICAL
-- structured diagnostics to `check --json` on the same file — same code, same
-- envelope), then, only if clean, the real emit+clang build. A build-stage
-- failure (emitter/clang) becomes a `cjBuildFailedJson` envelope instead of the
-- plain rendered `BuildErr` text; a clean build prints the (empty-diagnostics)
-- gate JSON as its success marker, mirroring `check --json`'s clean output —
-- no separate "built X -> Y" prose on this channel, so a machine consumer sees
-- exactly one shape regardless of outcome.
runBuildJsonCmd : List String -> Bool -> String -> String -> String -> Option String -> BuildTarget -> <IO> Unit
runBuildJsonCmd argv allowInternal root stdlibDir input outOpt target = match readFile input
  Err e =>
    let _ = println (cjFileNotFoundJson input e)
    exit 1
  Ok _ =>
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    match readPreludeFile rtPath
      Err msg =>
        let _ = println (cjBuildFailedJson input msg)
        exit 1
      Ok rsrc => match readPreludeFile corePath
        Err msg =>
          let _ = println (cjBuildFailedJson input msg)
          exit 1
        Ok csrc =>
          let (json, hasErr) = checkJsonFile allowInternal rsrc csrc input stdlibDir
          if hasErr then
            let _ = println json
            exit 1
          else
            let medaka = envOr "MEDAKA" "medaka"
            let cc = envOr "CC" "clang"
            let keepIrCli = hasFlag "--keep-ir" argv
            let outPath = match outOpt
              Some o => o
              None => defaultOutPath target input
            match runBuild root medaka cc target input outPath keepIrCli
              BuildOk _ => println json
              BuildErr msg =>
                let _ = println (cjBuildFailedJson input msg)
                exit 1

-- The `{"files":[...]}` envelope for a target that could not be read at all —
-- a file-not-found/unreadable-path diagnostic, unlocated (no source to point
-- into), carrying its own stable code so a caller keying off `code` (per
-- AGENTS.md) can distinguish "the file doesn't exist" from "the module
-- doesn't exist" (R-MODULE-LOAD).
cjFileNotFoundJson : String -> String -> String
cjFileNotFoundJson target err =
  let msg = "cannot read file '\{target}': \{err}"
  let diagJson = jObject [
    ("code", JString "R-FILE-NOT-FOUND"),
    ("kind", JString "resolve"),
    ("message", JString msg),
    ("range", JNull),
    ("severity", JInt 1),
    ("source", JString "medaka"),
  ]
  let filesJson = jObject [("file", JString target), ("diagnostics", jArray [diagJson])]
  stringify (jObject [("files", jArray [filesJson])])

isDiagError : Diag -> Bool
isDiagError (Diag SevError _ _ _ _ _) = True
isDiagError _ = False

isDiagWarn : Diag -> Bool
isDiagWarn d = not (isDiagError d)

-- ── the ONE typecheck warning `run`/`build` surface (F-3d, #614/#311) ───────
-- 🚨 READ THIS BEFORE WIDENING IT TO `isDiagWarn`.  That was tried, on the reasoning
-- that `run`/`build` "should show the same warnings `check` does", and it is wrong on
-- three counts, each measured:
--
--  (1) IT IS NOT THE ACCEPTANCE CRITERION.  F-3d's criterion is "nothing that was
--      LOUD goes silent".  The only diagnostic that was loud on `run`/`build` before
--      F-3d is the coherence reject F-3d demoted.  Every other warning on the
--      `matchWarnings` channel was ALREADY invisible on those verbs and stays exactly
--      as it was — not a regression, and not this change's to fix.
--  (2) SPEW, ~96% FALSE.  The channel is populated over the WHOLE MODULE GRAPH, and
--      `checkGuardExhaustivenessWith` draws its constructor oracle from the graph
--      rather than from the scrutinee's own type — so a fully exhaustive
--      `List`-matching function is reported "Missing case: `Text _`", `Text` being a
--      constructor of an unrelated type in another module (issue 1185, PRE-EXISTING).
--      Measured: `medaka build compiler/driver/medaka_cli.mdk` went 0 → 4896 stderr
--      lines, 1249 of them demanding that phantom `Text _`; a 25-line three-module
--      toy went 0 → 20, all false.  That makes `build` ~200× noisier than `check`.
--  (3) PERF.  Surfacing the channel means RENDERING it, and rendering a located
--      diagnostic materialises the containing file's lines (`ppDiagCliSrc` →
--      `srcLinesArr`) — a cost paid per file whose channel is non-empty.
--      Interleaved A/B on a quiet box: multi-module `check` 16.0–17.1 s → 38.9–40.6 s
--      with byte-identical stdout.  Narrowing to one code removes the render, which
--      fixes that at its cause rather than optimising around it.
--
-- So: exactly the demoted code, nothing else.  Widening this predicate is a decision
-- about which verb is the diagnostic one, not a cleanup.
coherenceWarnCode : String
coherenceWarnCode = "W-INCOMPARABLE-IMPLS"

-- #1499 / D1.  The predicate above is now a MEMBERSHIP TEST over a short
-- allowlist, not a single-literal test — and the three measured objections
-- recorded above do NOT reach the second member.  `W-PRELUDE-METHOD-SHADOW` has
-- no oracle at all (a pure name-set intersection, so it cannot be false), fires
-- at most ONCE PER COLLIDING INTERFACE-METHOD DECLARATION, and measures zero
-- occurrences across compiler/, stdlib/ and sqlite/ — so both the (2) spew and
-- (3) render costs are bounded by the collision count rather than by the module
-- graph.  This list is the decision, taken deliberately; it is not a place to
-- park codes, and every addition owes the same three measurements.
runBuildWarnCodes : List String
runBuildWarnCodes = [coherenceWarnCode, "W-PRELUDE-METHOD-SHADOW"]

isCoherenceWarn : Diag -> Bool
isCoherenceWarn (Diag SevWarning c _ _ _ _) = contains c runBuildWarnCodes
isCoherenceWarn _ = False

-- Drop the loc-free "Warning: …" lines runCheck bundles into its scheme dump, so
-- the located re-render (emitLocatedWarnings) is the single warning surface —
-- otherwise the CLI would print each warning twice (loc-free + located).  Scheme
-- lines are "name : type", never "Warning: …", so this only removes warnings.
stripWarningLines : String -> String
stripWarningLines s =
  joinNl (filter (l => not (startsWith "Warning: " l)) (splitNl s))

-- 0.1.0 preview UX (audit #6): filter `runCheck`'s "name : scheme" dump down to
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
  let n = length (filter (/= "") (splitNl filtered))
  "-- \{target}: ok (\{intToString n} declaration(s) checked, 0 errors)"

namesUserBinding : OrdMap Unit -> String -> Bool
namesUserBinding names l = match schemeLineName l
  Some n => omHasKey n names
  None => False

-- Every name a top-level Decl of this file introduces into value scope,
-- regardless of `pub` (single-file `check` has no module boundary to gate on).
topLevelNames : List Decl -> List String
topLevelNames [] = []
topLevelNames ((DAttrib _ d)::rest) = topLevelNames [d] ++ topLevelNames rest
topLevelNames ((DFunDef _ n _ _)::rest) = n :: topLevelNames rest
topLevelNames ((DTypeSig _ n _)::rest) = n :: topLevelNames rest
topLevelNames ((DExtern _ n _)::rest) = n :: topLevelNames rest
topLevelNames ((DLetGroup _ binds)::rest) = map letBindName binds
  ++ topLevelNames rest
topLevelNames (_::rest) = topLevelNames rest

letBindName : LetBind -> String
letBindName (LetBind n _) = n

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
emitHiddenDiagNote n =
  ePutStrLn
    "\{intToString n} further diagnostic(s) in imported modules; rerun with --json to see them"

-- The (path, src, coherence-warnings) triple of a SINGLE-file analysis.  The
-- single-module twin of what `locatedProjectDiags` returns, so both `run` arms hand
-- `finishRunEval` the SAME shape.
--
-- ⚠️ TRIPLES, NOT PRE-RENDERED STRINGS, and the reason is `--json`.  An earlier
-- revision passed `List String` rendered by `ppDiagCliSrc` at the call site — human
-- caret text, committed before the renderer knew whether it was writing to a human
-- or to a machine.  On `medaka run --json` that put caret art on a stream whose
-- documented contract is a `Diag` JSON envelope, and `diff_compiler_eval_json`
-- (which captures stderr ALONE) caught it.  Deferring the rendering to the emit
-- site is what lets one carrier serve both.
cohWarnTriples : String -> String -> List Diag -> List (String, String, List Diag)
cohWarnTriples src file diags = match filter isCoherenceWarn diags
  [] => []
  ws => [(file, src, ws)]

-- Drop triples with no warnings, so `cjAllToJson` never emits a `"diagnostics":[]`
-- entry for a file that had nothing to say.
nonEmptyTriples : List (String, String, List Diag) -> List (String, String, List Diag)
nonEmptyTriples ts = filter tripleHasDiags ts

-- Every module's coherence warnings EXCEPT the entry module's.
--
-- 🚨 WHY `check` NEEDS THIS AND `run`/`build` DO NOT.  `checkRoute`'s multi-module arm
-- already surfaces the ENTRY's coherence warning — `runCheckModules` bundles it
-- loc-free into the scheme dump it prints to stdout, and `globalCoherenceConflict`'s
-- cross-module finding is attached to the entry module too — so re-emitting the whole
-- list here would double-print exactly the shapes that already work.  What that stdout
-- path CANNOT reach is an IMPORTED module's own ⊑-incomparable pair: `runCheckModules`
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
dropEntryTriple : List (String, String, List Diag) -> List (String, String, List Diag)
dropEntryTriple [] = []
dropEntryTriple [_] = []
dropEntryTriple (t::rest) = t :: dropEntryTriple rest

-- #1499: the human multi-module `check` EMIT site trims the entry triple instead
-- of dropping it, and the difference is one measured cell.  `dropEntryTriple`
-- exists because `runCheckModules` — printed immediately above that emit — already
-- carries the ENTRY module's `W-INCOMPARABLE-IMPLS` on the typecheck warning
-- channel, so re-rendering the entry triple would print it TWICE.
-- `W-PRELUDE-METHOD-SHADOW` is NOT on that channel (it is an `analyzeProject`-side
-- Diag from `preludeStandaloneShadows`), so dropping the entry triple whole left it
-- silent in exactly one cell: multi-module human `check` with the collision in the
-- ENTRY module — while `check --json`, `run`, `build` and the imported-module
-- position all reported it (all five measured on this diff).  Trimming BY CODE
-- keeps the de-duplication that motivated `dropEntryTriple` and gives every other
-- allowlisted code exactly one channel.  A code added to `runBuildWarnCodes` that
-- `runCheckModules` DOES print must be added to `onTypecheckWarnChannel` too, or
-- human `check` will double-report it on the entry.
trimEntryTriple : List (String, String, List Diag) -> List (String, String, List Diag)
trimEntryTriple [] = []
trimEntryTriple [(p, s, ds)] =
  [(p, s, filter (d => not (onTypecheckWarnChannel d)) ds)]
trimEntryTriple (t::rest) = t :: trimEntryTriple rest

onTypecheckWarnChannel : Diag -> Bool
onTypecheckWarnChannel (Diag _ c _ _ _ _) = c == coherenceWarnCode

tripleHasDiags : (String, String, List Diag) -> Bool
tripleHasDiags (_, _, []) = False
tripleHasDiags _ = True

-- #1348: writing REQUIRES `--write`. The bare form used to default to
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
data FmtMode = FmtWrite | FmtStdout | FmtCheck

fmtHelpText : String
fmtHelpText = stringConcat
  [
    "medaka fmt — Format .mdk file(s)\n",
    "\n",
    "Usage:\n",
    "  medaka fmt [--check | --stdout | --write] <path>...\n",
    "\n",
    "Read-only unless --write is given.\n",
    "\n",
    "  (default)    same as --check: reports files that are not formatted\n",
    "               (exit 1 if any); prints nothing when already formatted.\n",
    "               Never writes.\n",
    "  --check      explicit form of the default\n",
    "  --stdout     print the formatted result to stdout (single file only);\n",
    "               never writes\n",
    "  --write, -w  rewrite the file(s) in place and print a one-line summary\n",
    "               (\"formatted N file(s)\" / \"already formatted\")\n",
    "\n",
    "A path may be a file or a directory (recursively expanded; dotfiles and\n",
    "dot-dirs are skipped).\n",
  ]

runFmtCmd : List String -> <IO> Unit
runFmtCmd argv = match parseFmtArgs argv FmtCheck []
  Err msg =>
    let _ = ePutStrLn msg
    exit 2
  Ok (_, []) =>
    let _ = ePutStrLn "Usage: medaka fmt [--check | --stdout | --write] <path>..."
    exit 2
  -- `listDir` Err = literal file (EXACT original single-file behavior); Ok =
  -- a directory, recursively expanded.
  Ok (mode, [target]) => match listDir target
    Err _ => fmtOne mode target
    Ok _ => fmtManyTargets mode [target]
  Ok (mode, targets) => fmtManyTargets mode targets

-- Multiple targets and/or a directory target: expand to concrete .mdk files
-- and format each, aggregating. `--stdout` only makes sense for one file.
fmtManyTargets : FmtMode -> List String -> <IO> Unit
fmtManyTargets FmtStdout _ =
  let _ = ePutStrLn "medaka fmt: --stdout requires exactly one file"
  exit 2
fmtManyTargets mode targets =
  let files = flatMap expandLintTarget targets
  match files
    [] =>
      let _ = ePutStrLn "medaka fmt: no .mdk files found"
      exit 2
    _ =>
      let (hadErr, changed) = fmtFilesGo mode files (False, 0)
      let _ = match mode
        FmtWrite => putStrLn (fmtWriteSummaryLine changed)
        _ => ()
      if hadErr then exit 1 else ()

-- Fold over an expanded file list, formatting each and aggregating whether
-- any error occurred (read failure, parse error, or --check finding
-- unformatted output — mirrors `lintFilesGo`'s aggregation) AND, for
-- `--write`, how many files were actually rewritten (so the caller can print
-- the "#1348" summary line once for the whole batch rather than per file).
fmtFilesGo : FmtMode -> List String -> (Bool, Int) -> <IO> (Bool, Int)
fmtFilesGo _ [] acc = acc
fmtFilesGo mode (f::rest) (errAcc, changedAcc) =
  let (hadErr, changed) = fmtOneReport mode f
  fmtFilesGo
    mode
    rest
    (errAcc || hadErr, changedAcc + (if changed then 1 else 0))

-- One line summarizing a `--write` run over N files: 0 changed reads as
-- "already formatted" (mirrors `fmtOne`'s single-file wording), one file
-- changed keeps the singular, more than one pluralizes.
fmtWriteSummaryLine : Int -> String
fmtWriteSummaryLine 0 = "already formatted"
fmtWriteSummaryLine 1 = "formatted 1 file"
fmtWriteSummaryLine n = "formatted \{intToString n} files"

-- Like `fmtOne` but reports to stdout/stderr and RETURNS (hadErr, changed)
-- instead of exiting immediately, so `fmtFilesGo` can aggregate across many
-- files (the single-file path still calls `fmtOne` directly and exits per
-- its own original codes, unchanged). `changed` is only meaningful for
-- `FmtWrite` — every other mode returns `False` for it.
fmtOneReport : FmtMode -> String -> <IO> (Bool, Bool)
fmtOneReport mode file = match readFile file
  Err msg =>
    let _ = ePutStrLn "\{file}: \{msg}"
    (True, False)
  Ok src => match parseResult src
    Err e =>
      let _ = ePutStrLn (ppParseError src file e)
      (True, False)
    Ok _ =>
      let formatted = formatSource src
      match mode
        FmtStdout =>
          let _ = putStr formatted
          (False, False)
        FmtCheck => if formatted == src then (False, False)
        else
          let _ = ePutStrLn (file ++ ": not formatted")
          (True, False)
        FmtWrite => if formatted == src then (False, False)
        else match writeFile file formatted
          Err msg =>
            let _ = ePutStrLn "\{file}: \{msg}"
            (True, False)
          Ok _ => (False, True)

parseFmtArgs : List String -> FmtMode -> List String -> Result String (FmtMode, List String)
parseFmtArgs [] mode acc = Ok (mode, reverseL acc)
parseFmtArgs ("--check"::rest) _ acc = parseFmtArgs rest FmtCheck acc
parseFmtArgs ("--stdout"::rest) _ acc = parseFmtArgs rest FmtStdout acc
parseFmtArgs ("--write"::rest) _ acc = parseFmtArgs rest FmtWrite acc
parseFmtArgs ("-w"::rest) _ acc = parseFmtArgs rest FmtWrite acc
parseFmtArgs (x::rest) mode acc =
  if stringLength x > 0 && stringSlice 0 1 x == "-" then
    Err ("medaka fmt: unknown flag: " ++ x)
  else
    parseFmtArgs rest mode (x::acc)

fmtOne : FmtMode -> String -> <IO> Unit
fmtOne mode file = match readFile file
  Err msg =>
    let _ = ePutStrLn "\{file}: \{msg}"
    exit 2
  -- PARSE-ERROR-LOCATION Stage 1: surface a located parse error before
  -- formatSource's panicking `parse` fires a bare `parse error`.
  Ok src => match parseResult src
    Err e =>
      let _ = ePutStrLn (ppParseError src file e)
      exit 1
    Ok _ =>
      let formatted = formatSource src
      match mode
        FmtStdout => putStr formatted
        FmtCheck => if formatted == src then ()
        else
          let _ = ePutStrLn (file ++ ": not formatted")
          exit 1
        FmtWrite => if formatted == src then putStrLn "already formatted"
        else match writeFile file formatted
          Err msg =>
            let _ = ePutStrLn "\{file}: \{msg}"
            exit 2
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
data CodeMode = CmDry | CmWrite | CmStdout

codemodHelpText : String
codemodHelpText = stringConcat
  [
    "medaka codemod — Apply a named source-preserving AST transform\n",
    "\n",
    "Usage:\n",
    "  medaka codemod <name> [flags] [--write|--stdout] <paths...>\n",
    "\n",
    "  (default)  dry-run: prints \"would rewrite: <file>\" per changed file,\n",
    "             exits 1 if any file would change. Never writes.\n",
    "  --write    rewrite only the files that actually change\n",
    "  --stdout   print one file's result (single file only)\n",
    "\n",
    "Any other --flag consumes the next token as its value, passed to the\n",
    "named codemod. Run `medaka codemod` with no arguments to list the\n",
    "available codemods.\n",
    "\n",
    "NOTE: `--help`/`-h` is only recognized in the FIRST position — as\n",
    "`medaka codemod --help`, before a codemod name. `medaka codemod <name>\n",
    "--help` is NOT special-cased (it is a codemod flag) and codemod-specific\n",
    "help does not exist yet.\n",
  ]

runCodemodCmd : List String -> <IO> Unit
runCodemodCmd [] = listCodemodsAndExit ()
runCodemodCmd (name::rest) = match findCodemod name
  None =>
    let _ = ePutStrLn "medaka codemod: unknown codemod '\{name}'"
    listCodemodsAndExit ()
  Some cm => match splitCodemodArgv rest CmDry [] []
    Err msg =>
      let _ = ePutStrLn msg
      exit 2
    Ok (mode, cargs, targets) => match codemodMk cm cargs
      Err msg =>
        let _ = ePutStrLn "medaka codemod \{name}: \{msg}"
        exit 2
      Ok xf =>
        let files = flatMap expandLintTarget targets
        match files
          [] =>
            let _ = ePutStrLn "medaka codemod: no .mdk files found"
            exit 2
          _ => match mode
            CmStdout => match files
              [one] => codemodStdout xf (codemodWarnDecls cm cargs) one
              _ =>
                let _ = ePutStrLn "medaka codemod: --stdout requires exactly one file"
                exit 2
            _ =>
              if codemodFilesGo mode xf (codemodWarnDecls cm cargs) files False then
                exit 1
              else
                ()

listCodemodsAndExit : Unit -> <IO> Unit
listCodemodsAndExit _ =
  let _ = putStrLn "Usage: medaka codemod <name> [flags] [--write|--stdout] <paths...>"
  let _ = putStrLn ""
  let _ = putStrLn "Available codemods:"
  let _ = putStrLn codemodListing
  exit 2

-- Split the post-name argv into (mode, codemod-flags, paths).  --write/--stdout
-- are consumed as modes; any other `--flag` is a codemod flag that consumes the
-- NEXT token as its value (the effect-labels convention: --strip <v>, --rename
-- <v>); everything else is a target path.
splitCodemodArgv : List String -> CodeMode -> List String -> List String -> Result String (CodeMode, List String, List String)
splitCodemodArgv [] mode cargs paths = Ok (mode, reverseL cargs, reverseL paths)
splitCodemodArgv ("--write"::rest) _ cargs paths =
  splitCodemodArgv rest CmWrite cargs paths
splitCodemodArgv ("--stdout"::rest) _ cargs paths =
  splitCodemodArgv rest CmStdout cargs paths
splitCodemodArgv (tok::rest) mode cargs paths =
  if startsWith "--" tok then match rest
    v::rest2 => splitCodemodArgv rest2 mode (v :: tok::cargs) paths
    [] => Err "medaka codemod: flag '\{tok}' requires a value"
  else splitCodemodArgv rest mode cargs (tok::paths)

-- --stdout for a single file: parse errors exit 1, otherwise print the rewritten
-- (or, if unchanged, the original) source.  Advisory warnings go to stderr.
codemodStdout : (Decl -> (Decl, Bool)) -> (List Decl -> List String) -> String -> <IO> Unit
codemodStdout xf warnFn file = match readFile file
  Err msg =>
    let _ = ePutStrLn "\{file}: \{msg}"
    exit 2
  Ok src => match codemodSource xf src
    Err e =>
      let _ = ePutStrLn (ppParseError src file e)
      exit 1
    Ok result =>
      let _ = emitCodemodWarns warnFn file src
      match result
        None => putStr src
        Some out => putStr out

-- Dry-run / --write fold over an expanded file list.  Returns whether the
-- process should exit 1: for dry-run that is "any file would change"; for
-- --write it is "any read/parse/write error" (a successful rewrite is exit 0).
codemodFilesGo : CodeMode -> (Decl -> (Decl, Bool)) -> (List Decl -> List String) -> List String -> Bool -> <IO> Bool
codemodFilesGo _ _ _ [] acc = acc
codemodFilesGo mode xf warnFn (f::rest) acc =
  let signal = codemodOneReport mode xf warnFn f
  codemodFilesGo mode xf warnFn rest (acc || signal)

codemodOneReport : CodeMode -> (Decl -> (Decl, Bool)) -> (List Decl -> List String) -> String -> <IO> Bool
codemodOneReport mode xf warnFn file = match readFile file
  Err msg =>
    let _ = ePutStrLn "\{file}: \{msg}"
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
emitWarnLines file (w::ws) =
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

runNewCmd : List String -> <IO> Unit
runNewCmd [arg] =
  if arg == "--help" || arg == "-h" then putStrLn newUsageLine
  else
    if stringLength arg > 0 && stringSlice 0 1 arg == "-" then
      let _ = ePutStrLn ("medaka new: unknown option '" ++ arg ++ "'")
      let _ = ePutStrLn newUsageLine
      exit 2
    else
      let code = newProject arg
      if code == 0 then () else exit code
runNewCmd _ =
  let _ = ePutStrLn newUsageLine
  exit 2

-- ── build ─────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `build` arm (Build_cmd.run) + build_main.mdk: parse
-- `<entry.mdk> [-o <out>]`, then drive build_cmd.runBuild (emit IR via a fresh
-- emitter subprocess → clang + C runtime + Boehm GC → native binary).  Paths
-- come from the environment (MEDAKA_ROOT/MEDAKA/CC) since compiler has no
-- getcwd/executable_name extern.  MEDAKA defaults to "./medaka" so a build with
-- no MEDAKA set re-invokes THIS native binary as the emitter host (no OCaml).
runBuildCmd : List String -> <IO> Unit
runBuildCmd argv =
  if hasFlag "--help" argv || hasFlag "-h" argv then buildUsage ()
  else match snapFlagValue "--emit-rt-obj" argv
    -- `medaka build --emit-rt-obj <path>`: precompile runtime/medaka_rt.c to a
    -- reusable object with EXACTLY the flags a normal link would apply, then exit.
    -- No input .mdk is required (or read) in this mode — it compiles only the C
    -- runtime.  A CI gate points MEDAKA_RT_OBJ at the result to skip the redundant
    -- per-build recompile of the identical runtime.
    Some objPath =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let cc = envOr "CC" "clang"
      match emitRtObj cc root objPath
        BuildOk msg => println msg
        BuildErr msg =>
          let _ = ePutStrLn msg
          exit 1
    None => match snapFlagValue "--emit-prelude-obj" argv
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
          BuildOk msg => println msg
          BuildErr msg =>
            let _ = ePutStrLn msg
            exit 1
      -- #1078: `--json` is now a recognized flag (stripped by parseBuildGo,
      -- above) rather than a phantom second positional. Dispatch to a
      -- dedicated function per mode rather than inlining the branch here —
      -- `runBuildJsonCmd` reuses `checkJsonFile` (the SAME structured pass
      -- `check --json` runs) for the front-end gate and wraps a genuine
      -- emit/clang failure in the same `{"files":[...]}` `Diag` envelope, so
      -- one JSON shape covers every failure mode, front-end or backend; the
      -- plain-text arm (`runBuildPlainCmd`) is the pre-#1078 body, unchanged.
      None => if hasFlag "--json" argv then runBuildJsonEntry argv else runBuildPlainCmd argv

-- The pre-#1078 plain-text `medaka build` body (parse args → typecheck gate →
-- emit+clang), split out of `runBuildCmd` so the `--json` dispatch above
-- doesn't have to interleave two argument-parsing arms at one indent level.
runBuildPlainCmd : List String -> <IO> Unit
runBuildPlainCmd argv =
  let perfOn = perfEnabled ()
  let perfT0 = now ()
  match parseBuildArgs argv
    Err msg =>
      let _ = ePutStrLn msg
      exit 1
    Ok (input, outOpt, target) => if not (fileExists input) then
      let _ = ePutStrLn ("error: no such file: " ++ input)
      exit 1
    else
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let medaka = envOr "MEDAKA" "medaka"
      let cc = envOr "CC" "clang"
      let inputAbs = input
      let allowInternal = hasFlag "--allow-internal" argv
      let keepIrCli = hasFlag "--keep-ir" argv
      let outPath = match outOpt
        Some o => o
        None => defaultOutPath target input
      match typecheckGate allowInternal root inputAbs
        TGErr msg =>
          let _ = ePutStrLn msg
          exit 1
        -- Warnings BEFORE the emitter runs, so they precede clang's own output
        -- and any `built <in> -> <out>` line — the same order `check` uses and
        -- the order a reader scanning a build log expects.  They never change
        -- the exit code.
        TGOk gateWarns =>
          let _ = emitWarningLines gateWarns
          let perfTTc = now ()
          let _ = emitPhase perfOn "typecheck" (perfTTc - perfT0) input
          match runBuild root medaka cc target inputAbs outPath keepIrCli
            BuildOk msg =>
              let perfTEmit = now ()
              let _ = emitPhase perfOn "emit" (perfTEmit - perfTTc) input
              let _ = emitTotal perfOn (perfTEmit - perfT0)
              println msg
            BuildErr msg =>
              let _ = ePutStrLn msg
              exit 1

-- `medaka build --json`'s own argument-parsing arm: a flag error still goes
-- through `parseBuildArgs`, but a bad-args message is now the JSON envelope
-- (`cjBuildFailedJson`, target "" — genuinely span-less, no input file was
-- even identified) rather than plain text, so a `--json` caller never has to
-- fall back to scraping stderr prose for THIS failure mode either.
runBuildJsonEntry : List String -> <IO> Unit
runBuildJsonEntry argv = match parseBuildArgs argv
  Err msg =>
    let _ = println (cjBuildFailedJson "" msg)
    exit 1
  Ok (input, outOpt, target) =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let stdlibDir = root ++ "/stdlib"
    let allowInternal = hasFlag "--allow-internal" argv
    runBuildJsonCmd argv allowInternal root stdlibDir input outOpt target

-- `medaka build --help` / `-h`: a subcommand-local usage, since the global
-- `usage()` (only matched when --help/-h is argv[0]) never sees this — dispatch
-- routes "build"::rest to runBuildCmd before the top-level --help arm gets a
-- chance.  Exists specifically so --keep-ir (and the other build-only flags)
-- are discoverable without reading the source.
buildUsage : Unit -> <IO> Unit
buildUsage _ = putStrLn (stringConcat
  [
    "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>] [--keep-ir] [--allow-internal] [--json]\n",
    "\n",
    "  -o <out>          output path for the binary (default: <file> with its extension dropped)\n",
    "  --target <t>      backend: native (LLVM + clang, default) or wasm (WasmGC + wasm-tools)\n",
    "  --json            emit the {\"files\":[...]} structured-diagnostics envelope (same\n",
    "                    schema as `medaka check --json`) instead of human text; a genuine\n",
    "                    build-stage (emitter/clang) failure carries code R-BUILD-FAILED\n",
    "  --keep-ir         keep the emitted IR (.ll for native, .wat for wasm) at <out>.ll/.wat\n",
    "                    instead of discarding it with the build's scratch directory; the\n",
    "                    kept path is printed. Env var MEDAKA_KEEP_IR=1 does the same for a\n",
    "                    build invoked by something else (e.g. a test harness)\n",
    "  --allow-internal  permit internal-only externs outside stdlib/\n",
    "  --emit-rt-obj <p> compile only runtime/medaka_rt.c to a reusable object at <p> (with\n",
    "                    the same flags a normal link uses) and exit; point MEDAKA_RT_OBJ at\n",
    "                    it to skip recompiling the runtime on every subsequent build\n",
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
  ])

-- Default output path per target: native drops the extension (a bare exe name);
-- wasm appends `.wasm` to the entry's base.
defaultOutPath : BuildTarget -> String -> String
defaultOutPath TNative input = chopExt (baseOf input)
defaultOutPath TWasm input = chopExt (baseOf input) ++ ".wasm"
-- G1 (SOUNDNESS): typecheck the whole module graph BEFORE shelling out to
-- the emitter.  runBuild emits/clangs whatever the emitter produces — for
-- an ill-typed program that is garbage (the G1 bug), so we abort here on any
-- type error.  Mirrors the OCaml driver's STEP-0 check gate.

-- G1 typecheck gate result: clean / a diagnostic (resolve or type error, or a
-- pre-typecheck read/load failure) whose message we surface verbatim.
-- ⚠️ `TGOk` CARRIES THE WARNINGS, and that is the whole reason it has a payload.
-- `build`'s gate used to be a bare Bool-shaped verdict, so every warning the check
-- it runs produced was computed and dropped — `medaka build` had NO warning surface
-- at all, for any warning class.  That was invisible while the typecheck channel
-- carried only non-exhaustive-match warnings (which `check` still showed); F-3d
-- demoted a formerly-loud coherence reject onto the same channel, at which point a
-- diagnostic `build` used to print became a silent accept.  The lines are rendered
-- by the gate (which knows each module's own source) and emitted by the caller.
--
-- ⚠️ RENDERED `String`s HERE, TRIPLES ON THE `run` PATH — an asymmetry that is a
-- FACT ABOUT THIS PLAIN-TEXT CODE PATH, not the whole CLI. #1078 gave `medaka
-- build` a `--json` flag, but it does NOT flow through `typecheckGate`/`TGOk`
-- at all: `runBuildCmd` branches on `jsonMode` BEFORE reaching this function and
-- routes to `runBuildJsonCmd` instead, which reuses `checkJsonFile` (the same
-- structured pass `check --json` runs) for the front-end gate and wraps a
-- build-stage failure in `cjBuildFailedJson`. So this comment's original
-- warning still holds for THIS (human-text) path specifically: `typecheckGate`
-- itself was never changed to carry structure, and if some future caller starts
-- routing `--json` through it, that payload must become triples and follow
-- `finishRunEval`'s `pendingRunDiags` discipline, or it reproduces the bug that
-- fix exists for.
data TypecheckGate = TGOk (List String) | TGErr String

-- Load the entry + transitive imports and run the SAME front-end `medaka check`
-- runs, reporting whether any error fired AND rendering it exactly as `check`
-- does.  This must be the CHECK path, not the EMIT path (elaborateModules):
-- elaborateModules sets implInferEnabled and deliberately SKIPS checkImplObligations
-- (a check-only diagnostic the emit driver doesn't want), so an ill-typed program
-- like `"x" + 1` slips past hadTypeErrors and reaches the emitter, which fails
-- with a confusing downstream `emitter failed …`.  We instead mirror checkRoute:
-- surface the exact diagnostic `check` prints and abort BEFORE the emitter/clang.
-- Read/load failures become TGErr (surfaced as-is) so the caller mirrors
-- runBuild/loadProgram's own diagnostics.
typecheckGate : Bool -> String -> String -> <IO> TypecheckGate
typecheckGate allowInternal root input =
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  let stdlibDir = root ++ "/stdlib"
  let roots = entrySearchRoots (dirOf2 input) ++ [stdlibDir]
  match readPreludeFile rtPath
    Err msg => TGErr msg
    Ok rsrc => match readPreludeFile corePath
      Err msg => TGErr msg
      Ok csrc => match readFile input
        Err msg => TGErr msg
        -- PARSE-ERROR-LOCATION Stage 1: a located parse diagnostic for the ENTRY.
        -- An IMPORTED module's parse error is located by the loader itself (#100)
        -- and rendered by moduleLoadErrText.
        Ok tsrc => match parseResult tsrc
          Err e => TGErr (ppParseError tsrc input e)
          -- #186/#1360: load with `loadProgramFilesLocatedE`, exactly as
          -- `runCheckCmd` and `runRunCmd` already do.  Plain `loadProgramE`
          -- gave this gate BOTH halves of the misattribution at once: it parses
          -- with placeholder-loc `parse` (every span collapses to 1:0) AND carries
          -- no per-module path, so an imported module's resolve error printed as
          -- `<entry>:1:0:` — wrong file AND wrong position.  The located loader
          -- carries real spans and the modId → path map `pathMap` threads below.
          Ok _ => match loadProgramFilesLocatedE (_ => None) input roots
            Err lerr => TGErr (moduleLoadErrText tsrc input stdlibDir lerr)
            Ok modsWithPath =>
              let mods = map dropModPath modsWithPath
              let pathMap = map modIdToPath modsWithPath
              let trusted = projectTrustedMods input roots stdlibDir mods
              -- #2072: the FFI-stamp discriminator, published to typecheck alongside the
              -- #1713 reference-trust set above.  DIFFERENT predicate, deliberately: this
              -- one is stdlib-root ownership with NO `allow-internal` opt-out.
              let (flatStdlib, ownedStdlib) = stdlibOwnership input roots stdlibDir mods
              let _ = setStdlibOwnership flatStdlib ownedStdlib
              typecheckGateRoute allowInternal trusted pathMap roots rsrc csrc tsrc input mods

-- Route by module count.  A single loaded module (no non-core imports) runs the
-- ACCURATE located check `medaka check` uses for single files — analyzeLocatedG
-- (which runs checkImplObligations, the very pass the emit path skips and the one
-- that catches `"x" + 1`'s `No impl of Num for String`) — and renders BYTE-IDENTICAL
-- carat diagnostics via ppDiagCliSrc.  This is the case the G1 bug fixture exercises.
--
-- The MULTI-MODULE case gates on `locatedProjectErrors` — LITERALLY the predicate
-- `checkRoute`'s multi-module arm uses (analyzeProject), so `build`/`run` reject
-- exactly the graphs `check` rejects, by construction (bug #40).
--
-- WHY THE OLD PREDICATE WAS UNSOUND (and could not be patched in place).  It was
-- `resolve diagnostics + elaborateModules + hadTypeErrors`.  But `elaborateModules`
-- sets `implInferEnabled := True`, and typecheck.mdk gates `checkImplObligations`
-- (the pass that raises `No impl of Display for Foo`) behind `if not
-- implInferEnabled.value`.  So the emit/eval elaboration STRUCTURALLY CANNOT record
-- a constraint / missing-impl error: `hadTypeErrors` stayed False and multi-module
-- `run` EXECUTED the ill-typed program, dying later on an unrelated runtime panic
-- (`intToString: not an Int`).  A plain unification `Type mismatch` DID set the
-- sticky flag, which is exactly why the hole hid for so long — probing with a type
-- mismatch shows correct behaviour.  Single-file `run`/`build` were never affected:
-- their arm already gates on `analyzeLocatedG`, which runs with implInferEnabled OFF.
--
-- WHY THIS DOES NOT OVER-REJECT.  The historical fear (recorded here as "the
-- multi-module obligation check flags the compiler's own source with a spurious
-- `No impl of Alternative for Parser`") named a predicate that no longer exists, and
-- the false positive it described was fixed by checkModuleFullDiags's `accAll` seed
-- (typecheck.mdk "Bug C": without the imported-standalone-shadow universe, `toList m`
-- routed to method dispatch → spurious `No impl of Foldable for Map`).  The proof that
-- analyzeProject is clean on compiler source is a REQUIRED CI check:
-- test/typecheck_compiler_source.sh runs exactly this driver over
-- compiler/driver/medaka_cli.mdk's whole import closure and fails on ANY
-- error-severity diagnostic.  So gating the oracle builds on it is safe.
--
-- The elaborate + hadTypeErrors gate is KEPT behind it as belt-and-braces (it is the
-- emit path's own view, and it is not a superset of nothing — a diagnostic only the
-- emit elaboration can see still aborts before the emitter).
typecheckGateRoute : Bool -> List String -> List (String, String) -> List String -> String -> String -> String -> String -> List (String, List Decl) -> <IO> TypecheckGate
typecheckGateRoute allowInternal trusted _ _ rsrc csrc tsrc target [(mid, decls)] =
  -- Same fix as checkRoute's single-module arm: honour the caller-computed
  -- `trusted` (owning-root) signal here too, not just `--allow-internal`.
  let diags = analyzeLocatedG mid (allowInternal || contains mid trusted) rsrc csrc tsrc
  let errs = filter isDiagError diags
  match errs
    [] =>
      -- #1236: `medaka build` used to have NO main-shape warning surface at
      -- all (defect 4 of the matrix) — fold it in beside the coherence
      -- warning, same rendering path (`renderTripleWarnings`), same order
      -- (`check`'s `warns ++ mainWarns`).  `mainShapeWarnings` re-elaborates
      -- only if the free arity check finds nothing, matching checkRoute.
      let mainWarns = mainShapeWarnings (desugar (parse rsrc)) (desugar (parse csrc)) [(mid, desugar decls)] decls
      let allWarns = cohWarnTriples tsrc target diags ++ nonEmptyTriples [(target, tsrc, mainWarns)]
      TGOk (flatMap renderTripleWarnings allWarns)
    _ => TGErr (joinNl (map (ppDiagCliLines (srcLinesArr tsrc) target) errs))
typecheckGateRoute allowInternal trusted pathMap roots rsrc csrc tsrc target mods =
  let rtD = desugar (parse rsrc)
  let coreD = desugar (parse csrc)
  let modsD = map desugarPair mods
  -- #186/#1360: attribute each module's resolve errors to its OWN file, via the
  -- loader's modId → path map — the SAME `resolveModulesToHumaneByPath` seam
  -- `checkRoute` has used since #41.  The single `target` fallback this replaced
  -- stamped EVERY imported module's error with the entry file's path.
  let resDiags = resolveModulesToHumaneByPath pathMap allowInternal trusted rtD coreD modsD
  match resDiags
    "" => match locatedProjectDiags allowInternal trusted target roots rsrc csrc
      -- CHECK-STRENGTH gate: the located per-module ERROR diagnostics, identical to
      -- what `medaka check` prints and to what `--json` reports.
      -- ⚠️ "identical to what `medaka check` prints" is true of ERRORS ONLY, and the
      -- earlier wording did not say so.  Human `medaka check` prints the ENTRY
      -- module's warnings; this gate's `TGOk` payload carries EVERY module's
      -- coherence warnings, so a `build` of a graph whose IMPORTED module has an
      -- incomparable overlap warns where `check` of the entry does not.  That is the
      -- behaviour F-3d wants — the reject it replaced was whole-graph too — but it is
      -- not identity, and reading it as identity is how the next reader "restores"
      -- the entry-only scoping and re-silences the imported case.
      (Some errText, _, _) => TGErr errText
      (None, projWarns, _) =>
        let _ = resetTypeErrorsSticky ()
        let _ = elaborateModules rtD coreD modsD
        match hadTypeErrors ()
          True => TGErr (locatedOrGeneric allowInternal trusted target roots rsrc csrc)
          -- #1236: same main-shape fold as the single-module arm above.
          -- `elaborateModules` just ran over the WHOLE graph (line above), so
          -- mainSchemeRef is already populated — no second typecheck pass.
          False =>
            let mainWarns = match lastModPair mods
              Some (_, edecls) => match mainArityWarning edecls
                Some d => [d]
                None => match mainNonUnitWarning edecls
                  Some d => [d]
                  None => []
              None => []
            let allWarns = projWarns ++ nonEmptyTriples [(target, tsrc, mainWarns)]
            TGOk (flatMap renderTripleWarnings allWarns)
    _ => TGErr resDiags

-- Parse `[-o <out>] [--target <native|wasm>]`; first remaining positional is the
-- input.  Default target is TNative (the LLVM/clang path) — purely additive, the
-- no-`--target` behaviour is unchanged.
parseBuildArgs : List String -> Result String (String, Option String, BuildTarget)
parseBuildArgs argv = parseBuildGo argv [] None TNative

parseBuildGo : List String -> List String -> Option String -> BuildTarget -> Result String (String, Option String, BuildTarget)
parseBuildGo [] acc out target = finishBuildArgs (reverseL acc) out target
parseBuildGo ("-o"::v::rest) acc out target =
  parseBuildGo rest acc (Some v) target
parseBuildGo ["-o"] _ _ _ = Err "error: -o requires an argument"
parseBuildGo ("--target"::v::rest) acc out _ = match parseTarget v
  Err msg => Err msg
  Ok t => parseBuildGo rest acc out t
parseBuildGo ["--target"] _ _ _ =
  Err "error: --target requires an argument (native|wasm)"
parseBuildGo ("--allow-internal"::rest) acc out target =
  parseBuildGo rest acc out target
-- --keep-ir: read separately via hasFlag in runBuildCmd (same convention as
-- --allow-internal above) — just strip it here so it doesn't fall through to
-- finishBuildArgs and get mistaken for the input file.
parseBuildGo ("--keep-ir"::rest) acc out target =
  parseBuildGo rest acc out target
-- #1078: `--json` used to fall through to `finishBuildArgs` and get counted as
-- a second positional ("takes exactly one input file") — a flag error read as
-- an argument-count error. Strip it here, same convention as --allow-internal/
-- --keep-ir above; `runBuildCmd` reads it separately via `hasFlag`.
parseBuildGo ("--json"::rest) acc out target = parseBuildGo rest acc out target
parseBuildGo (x::rest) acc out target = parseBuildGo rest (x::acc) out target

parseTarget : String -> Result String BuildTarget
parseTarget "native" = Ok TNative
parseTarget "wasm" = Ok TWasm
parseTarget other =
  Err ("error: unknown --target '" ++ other ++ "' (expected native|wasm)")

finishBuildArgs : List String -> Option String -> BuildTarget -> Result String (String, Option String, BuildTarget)
finishBuildArgs [] _ _ =
  Err "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>]"
finishBuildArgs [input] out target = Ok (input, out, target)
finishBuildArgs _ _ _ = Err "error: medaka build takes exactly one input file"

-- ── run ───────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `run` arm + eval_typed_modules_main.mdk: load the entry
-- + its transitive imports (dependency-first), desugar each, elaborateModules
-- (marker + typecheck route-stamping over the module graph), then evalModules
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
-- first positional after dropFlags is the entry; any further positionals are
-- the program's intended args (passthrough; observed via the native extern).
--
-- Shared eval tail: once the gate has ruled the program CLEAN and the whole
-- module graph has been elaborated (route-stamping via the per-module
-- typecheck, mainSchemeRef populated), force `main`.  Only reached AFTER the
-- check-strength gate below (single-file: analyzeLocatedG; multi-module:
-- resolve + hadTypeErrors), so a genuinely ill-typed program never reaches
-- evalModulesOutput (G1 soundness invariant).
-- [cohWarns] are the COHERENCE warnings (`W-INCOMPARABLE-IMPLS`, and ONLY those —
-- see `isCoherenceWarn` for why not the whole channel) that the caller's own gate
-- already computed, as (path, src, diags) triples.  ⚠️ A parameter rather than
-- something recomputed here because the two call sites derive them differently
-- (single-file: `analyzeLocatedG`'s diags; multi-module: `locatedProjectDiags`'
-- per-module triples) and recomputing would mean a second whole-graph front-end pass.
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
-- 🔧 #1236 (was: THE MAIN-SHAPE WARNING BELOW IS *NOT* ROUTED THROUGH ANY OF
-- THIS, DELIBERATELY): it now IS, the same way [cohWarns] is — staged into
-- `pendingRunDiags` under `--json` instead of emitted as human caret text on a
-- stream a machine consumer parses as JSON.  `test/error_quality_fixtures/
-- eval/main_not_value.mdk`'s `.json.out` golden moves from caret art to a
-- `Diag` JSON envelope (`test/diff_compiler_eval_json.sh`, re-captured) — that
-- was the bug (#1236 defect 3), not a blessed behaviour to preserve.
finishRunEval : String -> Bool -> (List Decl, List (String, List Decl)) -> List (String, List Decl) -> List (String, String, List Diag) -> <IO> Unit
finishRunEval target jsonMode elaborated mods cohWarns =
  -- 0.1.0 main-shape warning: elaborateModules already ran over the WHOLE graph,
  -- so mainSchemeRef is already populated — no extra typecheck pass needed.
  let mainWarns = match lastModPair mods
    Some (_, edecls) => match mainArityWarning edecls
      Some d => [d]
      None => match mainNonUnitWarning edecls
        Some d => [d]
        None => []
    None => []
  -- The demoted coherence warning first, matching `checkRoute`'s `warns ++
  -- mainWarns` order; on `--json` both fold into the ONE `pendingRunDiags`
  -- envelope this stream carries (see above), the main-shape one keyed to
  -- `target`'s own (path, src) pair so it renders with a real `Loc`.
  let _ = if jsonMode then ()
    else emitWarningLines (flatMap renderTripleWarnings cohWarns)
  let _ = if jsonMode then
      pendingRunDiags := (nonEmptyTriples (cohWarns ++ [(target, readFileSafe target, mainWarns)]))
    else
      emitLocatedWarnings (readFileSafe target) target mainWarns
  currentEvalFile := target
  runJsonMode := jsonMode
  let _ = putStr (runProgramOutput (fst elaborated) (snd elaborated))
  -- Reached only when the program did NOT panic (`panic` is a noreturn C abort), so
  -- this and `runtimePanic`'s merge are mutually exclusive — the envelope is emitted
  -- exactly once, never twice and never zero times.
  let _ = flushPendingRunDiags jsonMode
  -- #1681: the main-shape warning text already reads as a rejection ("'main'
  -- must be a value of type Unit …"), but `run` used to exit 0 anyway — making
  -- a program that computed and discarded a real value indistinguishable, by
  -- exit code, from one that ran clean. Since `main` was never applied/printed
  -- in this case (the underlying no-op behavior is unchanged, see the 0.1.0
  -- audit #3 note above), align the exit code with what the message already
  -- implies: nonzero, so a script/CI oracle keyed on exit code sees the truth.
  match mainWarns
    [] => ()
    _::_ => exit 1

flushPendingRunDiags : Bool -> <IO> Unit
flushPendingRunDiags False = ()
flushPendingRunDiags True = match !pendingRunDiags
  [] => ()
  ts => ePutStrLn (cjAllToJson ts)

runHelpText : String
runHelpText = stringConcat
  [
    "medaka run — Type-check and run a program (interpreter)\n",
    "\n",
    "Usage:\n",
    "  medaka run [--json] [--allow-internal] [--release] <file.mdk> [args...]\n",
    "\n",
    "  --json            emit the Diag JSON envelope for a compile-time error or\n",
    "                    a runtime panic, instead of human text\n",
    "  --allow-internal  permit internal-only externs outside stdlib/\n",
    "  --release         accepted, ignored (no-op for the interpreter path;\n",
    "                    kept for symmetry with `medaka build --release`)\n",
    "\n",
    "Args after <file.mdk> are passed through to the program's own `args`.\n",
    "Inline-eval (`-e <expr>`) is NOT supported — pass a file.\n",
  ]

runRunCmd : List String -> <IO> Unit
runRunCmd argv =
  let perfOn = perfEnabled ()
  let perfT0 = now ()
  let jsonMode = hasFlag "--json" argv
  match dropFlags argv
    [] =>
      let _ = ePutStrLn "usage: medaka run [--release] [--json] <file.mdk>"
      exit 1
    -- #219: a leading-`-` token `dropFlags` didn't recognize (e.g. `-e`) used
    -- to fall through as the entry `target`, so the loader rejected it as
    -- "unknown module: -e" — a message that sends the reader debugging a
    -- module path for what is actually a typo'd/unsupported flag. Report it
    -- as a flag error instead, mirroring `runFmtCmd`'s "-"-prefix detection
    -- (`parseFmtArgs`) and its "unknown flag: <x>" wording. Only the FIRST
    -- positional is checked — anything after it is the program's own
    -- passthrough args (ARGS NOTE above), which may legitimately start with
    -- `-`.
    target::_ if stringLength target > 0 && stringSlice 0 1 target == "-" =>
      let _ = ePutStrLn ("medaka run: unknown flag: " ++ target)
      exit 1
    target::progArgs =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let rtPath = root ++ "/stdlib/runtime.mdk"
      let corePath = root ++ "/stdlib/core.mdk"
      let stdlibDir = root ++ "/stdlib"
      let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
      let allowInternal = hasFlag "--allow-internal" argv
      -- publish the args AFTER the target for the run-path `args` extern
      -- (eval.mdk's pArgs reads this Ref): `medaka run prog.mdk a b` ⇒ ["a","b"],
      -- matching what the same program's compiled binary sees.
      progArgsRef := progArgs
      match readPreludeFile rtPath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok rsrc => match readPreludeFile corePath
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          -- Parse the user modules with parseLocated (real ELoc spans) so a
          -- runtime error (E-*) can report a correct file:L:C.  Plain loadProgram
          -- uses placeholder-loc `parse`, which collapses every span to 1:0.
          -- Structurally identical decls → eval output byte-identical.
          -- PARSE-ERROR-LOCATION Stage 1: surface a located parse error on the
          -- ENTRY file.  An IMPORTED module's parse error is located by the loader
          -- itself (#100) and rendered by moduleLoadErrText, so neither one is a
          -- bare `parse error` panic any more.  Error-path only; valid input is
          -- unaffected.
          Ok csrc => match parseResult (readFileSafe target)
            Err e =>
              let _ = ePutStrLn (ppParseError (readFileSafe target) target e)
              exit 1
            -- #186/#1360: keep the loader's per-module PATHS instead of dropping
            -- them at the load site.  They were already being carried here and
            -- discarded one line later, which is why every imported module's
            -- resolve error had to fall back to the entry file's path.
            Ok _ => match loadProgramFilesLocatedE (_ => None) target roots
              Err lerr =>
                let _ = ePutStrLn (moduleLoadErrText (readFileSafe target) target stdlibDir lerr)
                exit 1
              Ok modsWithPath =>
                let mods = map dropModPath modsWithPath
                let pathMap = map modIdToPath modsWithPath
                -- #1542: same per-module (modId -> path) map #41 already built
                -- here for resolve-phase attribution, now ALSO published to the
                -- evaluator so a RUNTIME error raised inside an imported module
                -- reports THAT module's file instead of the entry's.
                modulePathMap := pathMap
                let rtD = desugar (parse rsrc)
                let coreD = desugar (parse csrc)
                let modsD = map desugarPair mods
                let trusted = projectTrustedMods target roots stdlibDir mods
                -- #2072: the FFI-stamp discriminator, published to typecheck alongside the
                -- #1713 reference-trust set above.  DIFFERENT predicate, deliberately: this
                -- one is stdlib-root ownership with NO `allow-internal` opt-out.
                let (flatStdlib, ownedStdlib) = stdlibOwnership target roots stdlibDir mods
                let _ = setStdlibOwnership flatStdlib ownedStdlib
                let perfTLoad = now ()
                let _ = emitPhase perfOn "load" (perfTLoad - perfT0) target
                -- Route by module count, mirroring `checkRoute` EXACTLY, so that
                -- `run` accepts/rejects the SAME set of programs `medaka check`
                -- does (beta P0-1 / P1-8).  The old gate was resolve-errors +
                -- elaborate + hadTypeErrors for ALL programs — a WEAKER predicate
                -- than check's: it missed constraint/no-impl/coherence errors
                -- (so run silently executed ill-typed programs) AND spuriously
                -- fired on some check-clean programs (standalone-fn-shadows-iface).
                match modsD
                  [(runMid, _)] =>
                    -- Single-file: gate on the SAME located analysis `check`
                    -- uses (analyzeLocatedG → checkImplObligations et al.) and
                    -- render byte-identical caret diagnostics via ppDiagCliSrc,
                    -- instead of the opaque "type error in <file>" message (P1-8).
                    let tsrc = readFileSafe target
                    let diags = analyzeLocatedG runMid allowInternal rsrc csrc tsrc
                    let errs = filter isDiagError diags
                    match errs
                      [] =>
                        let _ = resetTypeErrorsSticky ()
                        let elaborated = elaborateModules rtD coreD modsD
                        let perfTCheck = now ()
                        let _ = emitPhase perfOn "check" (perfTCheck - perfTLoad) target
                        let _ = finishRunEval target jsonMode elaborated mods (cohWarnTriples tsrc target diags)
                        let perfTEval = now ()
                        let _ = emitPhase perfOn "eval" (perfTEval - perfTCheck) target
                        emitTotal perfOn (perfTEval - perfT0)
                      _ =>
                        let _ = ePutStrLn (joinNl (map (ppDiagCliLines (srcLinesArr tsrc) target) errs))
                        exit 1
                  _ =>
                    -- Multi-module: gate on `locatedProjectErrors` — the SAME
                    -- analyzeProject predicate `checkRoute`'s multi-module arm uses —
                    -- so `run` rejects exactly the graphs `check` rejects (bug #40).
                    --
                    -- The old gate here was resolve + elaborateModules +
                    -- hadTypeErrors, which is BLIND to constraint / missing-impl
                    -- errors: elaborateModules sets implInferEnabled, and typecheck
                    -- skips checkImplObligations under it.  So multi-module `run`
                    -- EXECUTED an ill-typed program (`println "\{Foo 1}"` with no
                    -- Display impl) and died on an unrelated `intToString: not an Int`
                    -- panic, while `check` on the same program printed the real
                    -- located `No impl of Display for Foo`.  See typecheckGateRoute
                    -- for why this is not an over-rejection.
                    -- #186/#1360: per-module attribution via the loader's
                    -- `pathMap`, the same seam `checkRoute` uses (#41).
                    let resDiags = resolveModulesToHumaneByPath pathMap allowInternal trusted rtD coreD modsD
                    match resDiags
                      -- `locatedProjectDiags`, not `locatedProjectErrors`: the same
                      -- single `analyzeProject` pass, but keeping the WARNINGS the
                      -- errors-only accessor discarded (see its own note).
                      "" => match locatedProjectDiags allowInternal trusted target roots rsrc csrc
                        (Some errText, _, _) =>
                          let _ = ePutStrLn errText
                          exit 1
                        (None, projWarns, _) =>
                          let _ = resetTypeErrorsSticky ()
                          let elaborated = elaborateModules rtD coreD modsD
                          match hadTypeErrors ()
                            True =>
                              -- Belt-and-braces: anything only the emit/eval
                              -- elaboration can see still aborts before eval.
                              let _ = ePutStrLn (locatedOrGeneric allowInternal trusted target roots rsrc csrc)
                              exit 1
                            False =>
                              let perfTCheck = now ()
                              let _ = emitPhase perfOn "check" (perfTCheck - perfTLoad) target
                              let _ = finishRunEval target jsonMode elaborated mods projWarns
                              let perfTEval = now ()
                              let _ = emitPhase perfOn "eval" (perfTEval - perfTCheck) target
                              emitTotal perfOn (perfTEval - perfT0)
                      _ =>
                        let _ = ePutStrLn resDiags
                        exit 1
-- G1 (SOUNDNESS): typecheck the WHOLE module graph and abort before
-- eval on ANY type error.  elaborateModules route-stamps via the
-- per-module typecheck (checkModuleFullImpl), which pushes into the
-- sticky error accumulator; resetTypeErrorsSticky clears it first so
-- hadTypeErrors reflects THIS run only.  A type error makes
-- evalModulesOutput miscompile (the G1 bug), so we never reach it.
-- Resolve-phase errors (e.g. PrivateNameAccess) ride a SEPARATE channel
-- hadTypeErrors does not cover, so resolveModulesToHumaneByPath is consulted
-- FIRST (mirroring `check`/`build`) and run aborts with the same humane
-- diagnostic before elaborate/eval.

desugarPair : (String, List Decl) -> (String, List Decl)
desugarPair (mid, p) = (mid, desugar p)

-- Drop the file-path component of a located-loader triple back to the
-- (modId, decls) pair shape loadProgram returns.
dropModPath : (String, String, List Decl) -> (String, List Decl)
dropModPath (mid, _, prog) = (mid, prog)

-- (modId, path, decls) → (modId, path): the per-module file map threaded into the
-- multi-module resolve renderer so an imported module's diagnostics report ITS
-- own path, not the entry's (#41).
modIdToPath : (String, String, List Decl) -> (String, String)
modIdToPath (mid, path, _) = (mid, path)

-- ASYNC-DESIGN Stage 2 (D5): route a `main : Async _` through the program's
-- `runAsync` (perform its stored row) instead of forcing it to an inert Async
-- value; a plain `main` keeps the ordinary force-for-effect path.  mainTypeIsAsync
-- reads the scheme elaborateModules just stashed, so this must run post-elaborate.
-- B2 (RUN-EFFECTS): the plain path is evalModulesOutputRun — evalModulesOutput
-- plus the real-I/O externs (File/Env/Stdin/Stderr/Clock), hence the `IO` row.
runProgramOutput : List Decl -> List (String, List Decl) -> <IO> String
runProgramOutput preludeDecls modules = match mainTypeIsAsync ()
  True => evalModulesOutputAsync preludeDecls modules
  False => evalModulesOutputRun preludeDecls modules

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
-- `--native` (#81 Stage 3) SWAPS the engine to native-only — sugar for
-- `--engines native`, NOT an addition to the interpreter (a flag named
-- "native" that silently also ran eval would mislead the exact stranger the
-- 0.1.0 bar is written for). `--engines eval,native` is the explicit
-- multi-engine form Stage 4's CI gate will use. Bare `medaka test <file>`
-- (neither flag) is unchanged: interpreter-only, byte-identical to
-- pre-#81-Stage-3 output. An unknown `--engines` name is a hard diagnostic
-- naming the valid set — never a silent drop, which would let a typo run
-- nothing and still exit 0 (the exact "didn't run looks like passed" failure
-- this whole arc exists to close).
testHelpText : String
testHelpText = stringConcat
  [
    "medaka test — Run doctests + property tests\n",
    "\n",
    "Usage:\n",
    "  medaka test [--native | --engines eval,native] [file.mdk | dir]\n",
    "\n",
    "  --native            run doctests through a compiled native binary\n",
    "                      instead of the interpreter (shorthand for\n",
    "                      --engines native)\n",
    "  --engines e1,e2,...  run the listed engine set (known: eval, native);\n",
    "                      exit code is the AND across engines\n",
    "\n",
    "--native and --engines are mutually exclusive. With neither, the default\n",
    "is the interpreter (eval) alone. A file.mdk or dir target is required.\n",
  ]

runTestCmd : List String -> <IO> Unit
runTestCmd argv = match parseTestEngines argv
  Err msg =>
    let _ = ePutStrLn "medaka test: \{msg}"
    exit 1
  Ok engines => match testTargets argv
    [] =>
      let _ = ePutStrLn "usage: medaka test [--native | --engines eval,native] [file.mdk | dir]"
      exit 1
    [target] => match listDir target
      Err _ => runTestOne engines target
      Ok _ => runTestManyTargets engines [target]
    targets => runTestManyTargets engines targets

-- `--engines <list>` and `--native` are MUTUALLY EXCLUSIVE — not "--engines
-- silently wins". Letting one silently override the other reproduces, in
-- miniature, the exact "flag quietly does something other than what the user
-- asked" failure the whole --native/--engines split exists to remove: a user
-- who typed --native and got only `--engines`'s answer, with no diagnostic,
-- has no way to know --native was ignored. So both together is a hard error
-- naming both flags, not a silent pick.  With neither given, the default is
-- `[EngInterp]`.
parseTestEngines : List String -> Result String (List Engine)
parseTestEngines argv = match (testFlagValue "--engines" argv, hasFlag "--native" argv)
  (Some _, True) => Err "--native and --engines are mutually exclusive; --native is shorthand for --engines native"
  (Some spec, False) => parseEngineList spec
  (None, True) => Ok [EngNative]
  (None, False) => Ok [EngInterp]

-- Comma list of engine names (`eval`/`native`) — mirrors `medaka snapshot
-- --stages a,b`'s `parseStages`: an unknown name is a hard error naming the
-- known set, not a silent drop.
parseEngineList : String -> Result String (List Engine)
parseEngineList spec =
  let names = filterList (/= "") (map stringTrim (splitLintNames spec))
  match names
    [] => Err "--engines requires at least one of: eval, native"
    _ => parseEngineNames names

parseEngineNames : List String -> Result String (List Engine)
parseEngineNames [] = Ok []
parseEngineNames (n::rest) = match engineOfName n
  None => Err "unknown engine '\{n}' (known: eval, native)"
  Some e => map (e :: _) (parseEngineNames rest)

engineOfName : String -> Option Engine
engineOfName "eval" = Some EngInterp
engineOfName "native" = Some EngNative
engineOfName _ = None

-- `--flag value` (space-separated, unlike lint's `--flag=v1,v2`) — same shape
-- as `medaka snapshot`'s `snapFlagValue`, kept local since neither module
-- exports its copy.
testFlagValue : String -> List String -> Option String
testFlagValue _ [] = None
testFlagValue _ [_] = None
testFlagValue name (a::v::rest) =
  if a == name then
    Some v
  else
    testFlagValue name (v::rest)

-- Non-flag args for `medaka test`, minus `--native` and the VALUE of
-- `--engines` (the shared `dropFlags` doesn't know about a value-taking
-- flag). Mirrors `snapshotTargets`/`lintTargets`.
testTargets : List String -> List String
testTargets [] = []
testTargets ("--engines"::_::rest) = testTargets rest
testTargets ("--native"::rest) = testTargets rest
testTargets (x::rest)
  | startsWith "--" x = testTargets rest
  | otherwise = x :: testTargets rest

-- Original single-file path, unchanged: read <MEDAKA_ROOT>/stdlib sources,
-- build search roots, run `runTest`, exit 1 on any failure/read-error.
runTestOne : List Engine -> String -> <IO> Unit
runTestOne engines target =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  let stdlibDir = root ++ "/stdlib"
  let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
  let ok = runTest engines rtPath corePath target roots
  if ok then () else exit 1

-- Directory/project/multi-target path: expand every target to concrete .mdk
-- files (SAME walk as lint/fmt), then run+aggregate. An empty resolved set
-- (empty dir, or a dir with no .mdk files) is reported and left at exit 0 —
-- "nothing to test" is not a failure, mirroring runTest's own vacuous-pass
-- convention for a single zero-doctest file.
runTestManyTargets : List Engine -> List String -> <IO> Unit
runTestManyTargets engines targets =
  let files = flatMap expandLintTarget targets
  match files
    [] =>
      let _ = putStrLn "medaka test: no .mdk files found"
      ()
    _ =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let rtPath = root ++ "/stdlib/runtime.mdk"
      let corePath = root ++ "/stdlib/core.mdk"
      let stdlibDir = root ++ "/stdlib"
      if testFilesGo engines rtPath corePath stdlibDir files False then
        exit 1
      else
        ()

-- Fold `runTest` over an expanded file list, aggregating whether ANY file
-- failed (tests failed, or the file itself couldn't be read/parsed).
testFilesGo : List Engine -> String -> String -> String -> List String -> Bool -> <IO> Bool
testFilesGo _ _ _ _ [] acc = acc
testFilesGo engines rtPath corePath stdlibDir (f::rest) acc =
  let roots = entrySearchRoots (dirOf2 f) ++ [stdlibDir]
  let ok = runTest engines rtPath corePath f roots
  testFilesGo engines rtPath corePath stdlibDir rest (acc || not ok)

-- ── doc ───────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `doc` arm + lib/doc.ml: read the target file, parse
-- (capturing decl positions + comments), typecheck a desugared copy through the
-- single-file path for inferred schemes, extract PUBLIC-decl doc entries, and
-- print Markdown to stdout.  Single-file only (OCaml `doc` is single-file too).
-- Prelude sources (runtime.mdk/core.mdk) come from MEDAKA_ROOT for scheme
-- inference, exactly as check/run/test do.
docHelpText : String
docHelpText = stringConcat
  [
    "medaka doc — Generate Markdown documentation for a file\n",
    "\n",
    "Usage:\n",
    "  medaka doc <file.mdk>\n",
    "\n",
    "Prints Markdown for every PUBLIC declaration (with inferred type\n",
    "schemes) in <file.mdk> to stdout. Single-file only.\n",
  ]

runDocCmd : List String -> <IO> Unit
runDocCmd argv = match dropFlags argv
  [] =>
    let _ = ePutStrLn "usage: medaka doc [file.mdk]"
    exit 1
  target::_ =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    match readPreludeFile rtPath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok rsrc => match readPreludeFile corePath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok csrc => match readFile target
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          Ok tsrc => putStr (runDoc rsrc csrc tsrc target)

-- ── check-policy ───────────────────────────────────────────────────────────
-- WS-1a of EFFECTS-CONFORMANCE-ROADMAP.md.  Mirrors bin/main.ml's `check-policy`
-- arm: parse `--allow L1,L2,… / --fn name / <file>`, type-check the plugin, read
-- the named fn's inferred effect row, and accept (+ run on a sample request) or
-- reject (+ print the call chain) per the policy.  Prelude sources come from
-- MEDAKA_ROOT, as check/run/doc do.  runCheckPolicy returns (report, accepted?);
-- we print the report and exit 0 (accept) / 1 (reject) — the OCaml arm exits the
-- same way.  Defaults (allow "Cache,Log", fn "transform") match the oracle.
checkPolicyHelpText : String
checkPolicyHelpText = stringConcat
  [
    "medaka check-policy — Check a plugin's inferred effects against an allow-list\n",
    "\n",
    "Usage:\n",
    "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]\n",
    "\n",
    "  --allow L1,L2,...  effect labels the plugin is permitted to use\n",
    "                     (default: Cache,Log)\n",
    "  --fn name          the function whose inferred effect row is checked\n",
    "                     (default: transform)\n",
    "\n",
    "Prints an accept/reject header; on accept, also runs the plugin on a\n",
    "sample request. Exit 0 on accept, 1 on reject.\n",
  ]

runCheckPolicyCmd : List String -> <IO> Unit
runCheckPolicyCmd argv = match parsePolicyArgs argv
  PolicyArgs None _ _ =>
    let _ = ePutStrLn "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]"
    exit 1
  PolicyArgs (Some target) allow fn =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    match readPreludeFile rtPath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok rsrc => match readPreludeFile corePath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok csrc => match readFile target
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          Ok tsrc =>
            -- runCheckPolicy forces the accepted-plugin evaluation before it
            -- returns, so an evaluation panic cannot leak an acceptance verdict.
            match runCheckPolicy rsrc csrc tsrc allow fn
              PolicyReject report =>
                let _ = putStr report
                exit 1
              PolicyAccept report => putStr report

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
manifestHelpText = stringConcat
  [
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

runManifestCmd : List String -> <IO> Unit
runManifestCmd argv = match parseManifestArgs argv
  ManifestArgs None _ =>
    let _ = ePutStrLn "usage: medaka manifest <file.mdk> [--fn name]"
    exit 1
  ManifestArgs (Some target) fn =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    match readPreludeFile rtPath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok rsrc => match readPreludeFile corePath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok csrc => match readFile target
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          Ok tsrc => putStr (runManifest rsrc csrc tsrc fn)

-- ── lint ──────────────────────────────────────────────────────────────────
-- Parse target file(s) and run lint rules over the raw pre-desugar AST.
-- Flags:
--   --fix                rewrite fixable findings in-place
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
-- Target resolution:
--   ≥1 explicit file args   → lint each in order
--   single directory arg    → lint all top-level .mdk files in that dir (sorted)
--   no file arg             → find medaka.toml project root, lint top-level .mdk files
--     (note: top-level only — subdirectory .mdk files are not walked recursively)
-- Exit 0 unless a SevError finding exists (only via --deny in v1 report mode).
lintHelpText : String
lintHelpText = stringConcat
  [
    "medaka lint — Lint files/dirs against style rules\n",
    "\n",
    "Usage:\n",
    "  medaka lint [paths...] [flags]\n",
    "\n",
    "  --fix                 rewrite fixable findings in-place\n",
    "  --json                emit the {\"files\":[...]} structured-diagnostics\n",
    "                       envelope instead of human text (--fix is ignored)\n",
    "  --cache                reuse per-file results for files whose content is\n",
    "                       unchanged (opt-in, like ESLint's --cache)\n",
    "  --disable=r1,r2,...    suppress findings from the named rules\n",
    "  --only=r1,...          keep only findings from the named rules\n",
    "  --deny=r1,...          promote findings from the named rules to error\n",
    "\n",
    "Target resolution: explicit file args are linted in order; a single\n",
    "directory arg lints its top-level .mdk files (not recursive); no args\n",
    "finds the medaka.toml project root and lints its top-level .mdk files.\n",
    "Exit 0 unless a SevError finding exists.\n",
  ]

runLintCmd : List String -> <IO> Unit
runLintCmd argv =
  let _ = assertLintFlagsHaveValues argv
  let disableNames = parseLintFlagList "--disable=" argv
  let onlyNames = parseLintFlagList "--only=" argv
  let denyNames = parseLintFlagList "--deny=" argv
  let fixMode = hasFlag "--fix" argv
  let jsonMode = hasFlag "--json" argv
  let fileArgs = lintTargets argv
  let _ = assertLintTargetsExist fileArgs
  let files = resolveLintTargets fileArgs
  if jsonMode then runLintJsonCmd disableNames onlyNames denyNames files
  else
    let multiFile = match files
      (_::_::_) => True
      _ => False
    let cacheCtx = lintCacheCtx (hasFlag "--cache" argv) fixMode
    -- `parsed` carries each readable target's (path, src, Positions, decls) out of
    -- the per-file pass so the cross-file tier reuses them instead of re-reading
    -- and re-parsing every file (#394).  It is EMPTY under --cache, where a hit
    -- has no parse to hand on — that path reaches the cross-file tier through the
    -- entries' cached occurrences instead (see runCrossFileReportCached).
    let (perFileErr, entries, parsed) =
      lintFilesGo fixMode multiFile disableNames onlyNames denyNames cacheCtx files False
    -- Cross-file rules only run in the multi-file REPORT path; a single target or
    -- --fix produces nothing (need ≥2 files), keeping single-file output identical.
    let crossErr =
      if not (multiFile && not fixMode) then False
      else match cacheCtx
        Some _ => runCrossFileReportCached disableNames onlyNames denyNames entries
        None => runCrossFileReport disableNames onlyNames denyNames parsed
    -- Persist AFTER reporting: the cache is an optimisation, so a failure to
    -- write one must never change what a run says or whether it exits 0.
    let _ = match cacheCtx
      Some (cacheDir, stamp) => storeEntries cacheDir stamp entries
      None => ()
    if perFileErr || crossErr then exit 1 else ()

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
lintCacheCtx : Bool -> Bool -> <IO> Option (String, String)
lintCacheCtx False _ = None
lintCacheCtx True True = None
lintCacheCtx True False
  | not crossFileCacheSound = None
  | otherwise =
    let root = findProjectRootOrSelf (canonicalizePath ".")
    let stamp = ruleSetStamp ()
    -- An empty stamp means the binary could not be read, so the rule set cannot
    -- be identified — the one input that makes a hit meaningful is missing.
    -- Decline rather than share a cache across unknown rule sets.
    if stamp == "" then None else Some (cacheDirOf root, stamp)

-- `medaka lint --json`: run the lint pipeline over every resolved target file
-- and emit the SAME `{"files":[{"file":...,"diagnostics":[...]}]}` envelope
-- `medaka check --json` emits (via `cjAllToJson`) — one schema for both
-- surfaces (#249).  Each `Finding` becomes a `Diag` via `findingToDiag`
-- (inside `lintFileDiagTriple`), which stamps the lint RULE NAME into the
-- diagnostic's `code` field.  Cross-file rules do not participate (JSON mode
-- is per-file, mirroring `check --json`'s own per-file shape); `--fix` is
-- ignored here.  Exit 1 iff any diagnostic is a hard error (severity 1) —
-- matches `runCheckJsonCmd`'s convention.
runLintJsonCmd : List String -> List String -> List String -> List String -> <IO> Unit
runLintJsonCmd disableNames onlyNames denyNames files =
  let triples = lintFilesToDiagTriples disableNames onlyNames denyNames files
  let _ = putStr (cjAllToJson triples)
  if anyList cjLintTripleHasErr triples then exit 1 else ()

-- Sequence `lintFileDiagTriple` over every target file, in order.  Mirrors
-- `lintFilesGo`'s explicit recursion — this codebase sequences an `<IO>`
-- list traversal by hand, not via `map` over an effectful function.
lintFilesToDiagTriples : List String -> List String -> List String -> List String -> <IO> List (String, String, List Diag)
lintFilesToDiagTriples _ _ _ [] = []
lintFilesToDiagTriples disable only deny (f::rest) =
  lintFileDiagTriple disable only deny f ::
    lintFilesToDiagTriples disable only deny rest

cjLintTripleHasErr : (String, String, List Diag) -> Bool
cjLintTripleHasErr (_, _, diags) = anyList diagIsError diags

-- Run the cross-file rule tier over the whole set, REUSING the parses the per-file
-- pass already produced (#394 — this used to call `parseLintFiles`, re-reading and
-- re-parsing every target, plus `readLintSrcs` for a third read of the same bytes).
-- Findings render AFTER the per-file output under a `cross-file:` header.
-- --only/--disable are honored inside `runCrossFileRules`; --deny promotion is
-- applied here (mirrors the per-file path).  Returns whether any finding is an
-- error severity (feeds the exit code).
runCrossFileReport : List String -> List String -> List String -> List (String, String, Positions, List Decl) -> <IO> Bool
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
-- ⚠️ THE JOIN RUNS EVERY TIME, over ALL files.  Only its per-file INPUTS are
-- cached.  A duplicate-body finding names file A because of file B, so caching
-- these findings would leave A's finding standing after B stopped duplicating
-- it — A is unchanged, so A hits.  Scenario 3 of
-- test/diff_compiler_lint_cache.sh is exactly that edit and exists to catch
-- anyone who tries it.  Callers must have checked `crossFileCacheSound`
-- (`lintCacheCtx` does).
runCrossFileReportCached : List String -> List String -> List String -> List LintEntry -> <IO> Bool
runCrossFileReportCached disableNames onlyNames denyNames entries =
  let raw = runCrossFileRulesFromOccs onlyNames disableNames (flatMap entryOccs entries)
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
parsedToTriple : (String, String, Positions, List Decl) -> (String, Positions, List Decl)
parsedToTriple (path, _, pos, decls) = (path, pos, decls)

parsedToSrc : (String, String, Positions, List Decl) -> (String, String)
parsedToSrc (path, src, _, _) = (path, src)

-- #1173: `--disable`/`--only`/`--deny` only accept the `--flag=v1,v2,...` form
-- (`parseLintFlagList`, `--flag=` prefix, matches the usage banner and the
-- pre-commit hook's own `--only="$X" --deny="$X"` usage). The space form
-- (`--deny rule-name`) is a plausible first guess and used to be accepted
-- silently: `lintTargets` skips any `--`-prefixed token but never consumes a
-- following value, so the rule name fell through as an ordinary positional
-- TARGET — the flag applied to nothing, and no diagnostic said so. Rejecting
-- the bare flag outright (rather than teaching `lintTargets` to consume a
-- value it would then have to validate as a rule list, not a path) keeps one
-- supported spelling instead of two silently-divergent ones.
lintValueFlags : List String
lintValueFlags = ["--disable", "--only", "--deny"]

assertLintFlagsHaveValues : List String -> <IO> Unit
assertLintFlagsHaveValues argv =
  let bad = filter (f => contains f argv) lintValueFlags
  if bad == [] then ()
  else
    let _ = ePutStrLn (stringConcat [
      "medaka lint: ",
      joinWith ", " bad,
      " require a value in the form --flag=<rule1,rule2,...> (a bare '",
      "--flag <rule>' space-separated form is not supported and would be silently",
      " ignored, so it is rejected instead)",
    ])
    exit 1

-- #1173: a lint target that is neither a listable directory nor a readable
-- file used to fall through `expandLintTarget`'s `Err _ => [target]` arm as a
-- literal path, which `lintFileDiagTriple` then reads via `readFileSafe` — the
-- same "" -on-error helper `checkJsonFile` uses — so a nonexistent path parsed
-- as EMPTY SOURCE and reported a clean 0-diagnostic result at exit 0. Fail
-- loudly up front instead (mirrors `assertSnapshotTargetsExist` above).
lintTargetExists : String -> <IO> Bool
lintTargetExists t = match listDir t
  Ok _ => True
  Err _ => fileExists t

assertLintTargetsExist : List String -> <IO> Unit
assertLintTargetsExist [] = ()
assertLintTargetsExist targets =
  let missing = filter (t => not (lintTargetExists t)) targets
  if missing == [] then ()
  else
    let _ = ePutStrLn "medaka lint: these targets do not exist:"
    let _ = ePutStrLn (joinNl (map (m => "  \{m}") missing))
    exit 1

-- Resolve file args to a concrete list of .mdk paths.
-- Empty args → project root mode (find medaka.toml, list top-level .mdk files).
-- Each non-empty arg is expanded individually: a path listDir succeeds on is
-- treated as a directory (recursively collected); else it's kept as a literal
-- file path. This applies uniformly whether one or many targets are given, so
-- `medaka lint dirA dirB` expands BOTH dirs (not just the first).
resolveLintTargets : List String -> <IO> List String
resolveLintTargets [] =
  let cwd = canonicalizePath "."
  match findProjectRoot cwd
    None =>
      let _ = ePutStrLn "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths"
      let _ = exit 1
      []
    Some root => collectMdkFiles root
resolveLintTargets targets = flatMap expandLintTarget targets

-- One target: a listable path is a directory (recursively collect its .mdk
-- files); otherwise a literal file path, kept as-is.
expandLintTarget : String -> <IO> List String
expandLintTarget target = match listDir target
  Ok _ => collectMdkFiles target
  Err _ => [target]

-- Join a directory path with an entry name (handles trailing slash).
lintPathJoin : String -> String -> String
lintPathJoin dir name =
  if endsWith "/" dir then
    dir ++ name
  else
    "\{dir}/\{name}"

-- Recursively collect every `.mdk` file under `dir`, sorted (deterministic).
-- Walks SUBDIRECTORIES; skips dot-entries (dotfiles AND dot-directories like
-- `.git`/`.claude`).  A failed top-level `listDir` reports once and yields [].
collectMdkFiles : String -> <IO> List String
collectMdkFiles dir = match listDir dir
  Err msg =>
    let _ = ePutStrLn "medaka lint: cannot list directory \{dir}: \{msg}"
    []
  Ok _ => sortUniqS (collectMdkFilesRec dir)

collectMdkFilesRec : String -> <IO> List String
collectMdkFilesRec dir = match listDir dir
  Err _ => []
  Ok entries => collectMdkEntries dir (filterNonDot entries)

collectMdkEntries : String -> List String -> <IO> List String
collectMdkEntries _ [] = []
collectMdkEntries dir (name::rest) = collectMdkEntry dir name
  ++ collectMdkEntries dir rest

-- One entry: a listable path is a subdirectory (recurse); otherwise a file,
-- kept iff it ends in `.mdk`.  Mirrors the dir/file discriminator used elsewhere
-- (listDir Ok = dir, Err = file).
collectMdkEntry : String -> String -> <IO> List String
collectMdkEntry dir name =
  let full = lintPathJoin dir name
  match listDir full
    Ok _ => collectMdkFilesRec full
    Err _ => if endsWith ".mdk" name then [full] else []

-- Drop dot-entries (dotfiles and dot-directories) from a listDir result.
filterNonDot : List String -> List String
filterNonDot [] = []
filterNonDot (n::rest)
  | startsWith "." n = filterNonDot rest
  | otherwise = n :: filterNonDot rest

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
lintFilesGo : Bool -> Bool -> List String -> List String -> List String -> Option (String, String) -> List String -> Bool -> <IO> (Bool, List LintEntry, List (String, String, Positions, List Decl))
lintFilesGo _ _ _ _ _ _ [] acc = (acc, [], [])
lintFilesGo fixMode multiFile disableNames onlyNames denyNames cacheCtx (f::rest) acc =
  if fixMode then
    let hadErr = lintOneFileFix onlyNames disableNames f
    lintFilesGo
      fixMode
      multiFile
      disableNames
      onlyNames
      denyNames
      cacheCtx
      rest
      (acc || hadErr)
  else
    let (hadErr, entries, parsed) = lintOneFileReport multiFile disableNames onlyNames denyNames cacheCtx f
    let (restErr, restEntries, restParsed) = lintFilesGo fixMode multiFile disableNames onlyNames denyNames cacheCtx rest (acc || hadErr)
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
lintOneFileReport : Bool -> List String -> List String -> List String -> Option (String, String) -> String -> <IO> (Bool, List LintEntry, List (String, String, Positions, List Decl))
lintOneFileReport multiFile disableNames onlyNames denyNames cacheCtx target = match readFile target
  Err msg =>
    let _ = ePutStrLn msg
    (True, [], [])
  Ok src =>
    let (entry, parsed) = lintEntryOf cacheCtx target src
    -- Suppress findings silenced by inline `-- lint-disable-*` directives before
    -- applying the CLI flag filters (--only/--disable/--deny).  Both the cached
    -- and uncached paths render from THIS one expression over the entry, so a
    -- hit and a miss cannot print different things: the only difference between
    -- them is where `entry` came from.
    let allFindings = applySuppressionsDirs entry.directives entry.findings
    let findings = applyFindingFilters disableNames onlyNames denyNames allFindings
    let srcLines = srcLinesArr src
    let output = joinNl (map (f => ppDiagCliLines srcLines target (findingToDiag f)) findings)
    let hasOutput = stringLength output > 0
    let _ = if multiFile && hasOutput then putStrLn (target ++ ":") else ()
    let _ = if hasOutput then putStrLn output else ()
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
lintEntryOf : Option (String, String) -> String -> String -> <IO> (LintEntry, List (String, String, Positions, List Decl))
lintEntryOf None target src =
  let (entry, pos, decls) = lintFileFresh target src "" False
  (entry, [(target, src, pos, decls)])
lintEntryOf (Some (cacheDir, stamp)) target src =
  let hash = contentHashOf src
  match loadEntry cacheDir stamp target hash
    Some hit => (hit, [])
    None =>
      let (entry, _, _) = lintFileFresh target src hash True
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
lintFileFresh : String -> String -> String -> Bool -> <IO> (LintEntry, Positions, List Decl)
lintFileFresh target src hash wantOccs =
  let (decls, pos) = parseWithPositionsLocated src
  (
    LintEntry {
      path = target,
      contentHash = hash,
      findings = lintProgram allRules target src pos decls,
      dupOccs = if wantOccs then fileDupOccs (target, pos, decls) else [],
      directives = collectDirectives src,
      dirty = True,
    },
    pos,
    decls,
  )

-- Fix a single file in-place.  Returns True only on I/O error (write errors exit 2).
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
        let _ = exit 2
        True
      Ok _ =>
        let _ = putStrLn "fixed \{intToString n} finding(s) in \{target}"
        False

-- All non-flag args in order (flags all start with --).
lintTargets : List String -> List String
lintTargets [] = []
lintTargets (x::rest)
  | startsWith "--" x = lintTargets rest
  | otherwise = x :: lintTargets rest

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
-- REPLACE (see TESTING-DESIGN.md §2.3: a missing oracle used to exit 2 = SKIP, and
-- a fresh clone ran zero tests and printed "0 failed"). Never let "I could not read
-- it" become an expected output. Fail loudly, up front.
assertSnapshotTargetsExist : List String -> <IO> Unit
assertSnapshotTargetsExist files =
  let missing = filter (f => not (fileExists f)) files
  if missing == [] then ()
  else
    let _ = ePutStrLn "medaka snapshot: these targets do not exist:"
    let _ = ePutStrLn (joinNl (map (m => "  \{m}") missing))
    exit 1

-- Lock 1, on its own, with its own message.  A `--bless` naming nothing is refused BEFORE
-- target expansion, so the refusal cannot be confused with "your glob matched no files".
assertBlessIsScoped : List String -> List String -> <IO> Unit
assertBlessIsScoped argv targets =
  if not (hasFlag "--bless" argv) || targets /= [] then ()
  else
    let _ = ePutStrLn "medaka snapshot: --bless requires explicit targets — there is no whole-suite bless."
    let _ = ePutStrLn "  Name what you are approving, e.g.:"
    let _ = ePutStrLn "    medaka snapshot --bless --out test/snapshots/compiler compiler/frontend/lexer.mdk"
    let _ = ePutStrLn "  (or, family-aware:  sh test/diff_compiler_snapshot_frontend.sh --bless compiler/frontend/lexer.mdk)"
    exit 1

snapshotHelpText : String
snapshotHelpText = stringConcat
  [
    "medaka snapshot — Per-stage snapshot tests\n",
    "\n",
    "Usage:\n",
    "  medaka snapshot [--check | --new | --bless] <paths...>\n",
    "                  [--out <dir>] [--stages <a,b,...>] [--isolate]\n",
    "\n",
    "One mode is REQUIRED, and the three are mutually exclusive:\n",
    "  --check   compare against the existing snapshot; write nothing\n",
    "  --new     create a MISSING snapshot; never touch an existing one\n",
    "  --bless   rewrite an EXISTING snapshot; never create one; requires\n",
    "            explicit targets (no whole-suite bless)\n",
    "\n",
    "  --out <dir>       snapshot directory (default derived from MEDAKA_ROOT)\n",
    "  --stages a,b,...   restrict to the named stages (default: every stage)\n",
    "  --isolate          run one process per fixture (debug aid for a crasher)\n",
    "\n",
    "A path may be a file or directory (recursively expanded).\n",
  ]

runSnapshotCmd : List String -> <IO> Unit
runSnapshotCmd argv =
  let root = match snapFlagValue "--root" argv
    Some r => r
    None => envOr "MEDAKA_ROOT" defaultMedakaRoot
  let sel = snapshotStages argv
  let targets = snapshotTargets argv
  let _ = assertBlessIsScoped argv targets
  let files = flatMap expandLintTarget targets
  let _ = assertSnapshotTargetsExist files
  if files == [] then
    let _ = ePutStrLn "usage: medaka snapshot [--check|--new|--bless] [--out <dir>] [--stages <a,b,…>] <paths...>"
    exit 1
  else
    if hasFlag "--worker" argv then runSnapshotWorker root sel files
    else match snapshotMode argv
      None =>
        let _ = ePutStrLn "medaka snapshot: pass --check (verify), --new (create missing snapshots) or --bless (rewrite existing ones)"
        exit 1
      Some mode =>
        let ok = runSnapshotSupervisor root mode (hasFlag "--isolate" argv) (snapFlagValue "--out" argv) sel files
        if ok then () else exit 1

-- Exactly one mode, and it is mandatory.  Two modes at once is a hard error rather than
-- a precedence rule: `--check --bless` is a person who does not know which one they
-- meant, and guessing for them is how a verify run turns into a rewrite run.
snapshotMode : List String -> <IO> Option SnapMode
snapshotMode argv =
  let modes = filterList (f => hasFlag f argv) ["--check", "--new", "--bless"]
  match modes
    ["--check"] => Some SnapCheck
    ["--new"] => Some SnapNew
    ["--bless"] => Some SnapBless
    [] => None
    many =>
      let _ = ePutStrLn "medaka snapshot: \{joinWith " " many} are mutually exclusive — pick one."
      let _ = exit 1
      None

-- `--stages parse,desugar,mark` restricts which sections a fixture renders (see
-- tools/snapshot.mdk).  Absent == every stage.  A typo'd stage name EXITS rather than
-- being dropped: silently rendering fewer sections than asked for would report a clean
-- pass over a stage that never ran.
snapshotStages : List String -> <IO> List String
snapshotStages argv = match snapFlagValue "--stages" argv
  None => []
  Some spec => match parseStages spec
    Ok names => names
    Err msg =>
      let _ = ePutStrLn "medaka snapshot: \{msg}"
      let _ = exit 1
      []

-- Non-flag args, minus the VALUE of the value-taking flags (--out/--root/--stages).
snapshotTargets : List String -> List String
snapshotTargets [] = []
snapshotTargets ("--out"::_::rest) = snapshotTargets rest
snapshotTargets ("--root"::_::rest) = snapshotTargets rest
snapshotTargets ("--stages"::_::rest) = snapshotTargets rest
snapshotTargets (x::rest)
  | startsWith "--" x = snapshotTargets rest
  | otherwise = x :: snapshotTargets rest

-- `--flag value` (space-separated, unlike lint's `--flag=v1,v2`).
snapFlagValue : String -> List String -> Option String
snapFlagValue _ [] = None
snapFlagValue _ [_] = None
snapFlagValue name (a::v::rest) =
  if a == name then
    Some v
  else
    snapFlagValue name (v::rest)

-- dirname on a POSIX path (mirrors build_cmd.dirOf, kept local to avoid an extra
-- import of a non-exported helper).
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
replUsageLine : String
replUsageLine = stringConcat
  [
    "medaka repl — Start the interactive REPL\n",
    "\n",
    "Usage:\n",
    "  medaka repl     Start an interactive session that reads expressions\n",
    "                 from stdin, evaluates them, and prints results until\n",
    "                 stdin closes (EOF) or you enter :quit.\n",
  ]

-- #657: argv used to be discarded (`runReplCmd _ = ...`), so `--help`/`-h`/any
-- bogus arg silently fell into the interactive read loop — which blocks on
-- stdin forever if stdin is an open terminal, the same shape as the bug
-- fixed in runLspCmd (#321), runMcpCmd (#299), and runNewCmd (#582). Blocking
-- on stdin with NO args is correct (that's the actual REPL); only an
-- explicit/unknown arg needs handling before the loop starts.
runReplCmd : List String -> <IO> Unit
runReplCmd [] =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  match readPreludeFile rtPath
    Err msg =>
      let _ = ePutStrLn msg
      exit 1
    Ok rsrc => match readPreludeFile corePath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok csrc =>
        let runtimeDecls = desugar (parse rsrc)
        let preludeDecls = desugar (parse csrc)
        let _ = initSession runtimeDecls preludeDecls
        replLoop ()
runReplCmd ("--help"::_) =
  let _ = putStrLn replUsageLine
  exit 0
runReplCmd ("-h"::_) =
  let _ = putStrLn replUsageLine
  exit 0
runReplCmd (bad::_) =
  let _ = ePutStrLn ("medaka repl: unknown option '" ++ bad ++ "'")
  let _ = ePutStrLn replUsageLine
  exit 1

-- ── lsp ───────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `lsp` arm (Lsp_server.run) + lsp_main.mdk: read
-- MEDAKA_ROOT/stdlib/{runtime,core}.mdk, then run the JSON-RPC-over-stdio
-- loop (initialize handshake + publishDiagnostics on didOpen/didChange).
--
-- Usage text for `medaka lsp --help` / `-h` — mirrors mcpUsage's one-line
-- description plus the stdio-blocking reminder, adapted for the Language
-- Server Protocol. A plain String (not a function) so it can be printed to
-- either stdout (help) or stderr (error), matching newUsageLine's shape
-- (#582) rather than mcpUsage's stdout-only one (#299).
lspUsageLine : String
lspUsageLine = stringConcat
  [
    "medaka lsp — Run the Language Server Protocol server over stdio\n",
    "\n",
    "Usage:\n",
    "  medaka lsp     Start the server; it reads JSON-RPC requests from stdin\n",
    "                 and writes responses to stdout until stdin closes (EOF).\n",
    "                 This is the normal, correct behavior for an LSP stdio\n",
    "                 server — it is not supposed to be interactive.\n",
  ]

-- #321: argv used to be discarded (`runLspCmd _ = ...`), so `--help`/`-h`/any
-- bogus arg silently fell into the JSON-RPC read loop — which blocks on stdin
-- forever if stdin is an open terminal. Blocking on stdin with NO args is
-- correct (that's the actual protocol); only an explicit/unknown arg needs
-- handling before the server starts. Structurally mirrors runMcpCmd (#299,
-- same file) since lsp — like mcp — takes no positional arguments in normal
-- use; the "unknown option" wording mirrors runNewCmd (#582).
runLspCmd : List String -> <IO> Unit
runLspCmd [] = runLspServerFromEnv ()
runLspCmd ("--help"::_) =
  let _ = putStrLn lspUsageLine
  exit 0
runLspCmd ("-h"::_) =
  let _ = putStrLn lspUsageLine
  exit 0
runLspCmd (bad::_) =
  let _ = ePutStrLn ("medaka lsp: unknown option '" ++ bad ++ "'")
  let _ = ePutStrLn lspUsageLine
  exit 1

runLspServerFromEnv : Unit -> <IO> Unit
runLspServerFromEnv _ =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  match readPreludeFile rtPath
    Err msg =>
      let _ = ePutStrLn msg
      exit 1
    Ok rsrc => match readPreludeFile corePath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok csrc => runServer rsrc csrc

-- Short usage blurb for `medaka mcp --help` / `-h` — mirrors the one-line
-- description `usage` (line ~284) gives mcp in the top-level help, plus the
-- reminder that it's a stdio server (so a reader knows why it blocks).
mcpUsage : Unit -> <IO> Unit
mcpUsage _ = putStrLn (stringConcat
  [
    "medaka mcp — Run the MCP server over stdio (JSON-RPC for agents)\n",
    "\n",
    "Usage:\n",
    "  medaka mcp     Start the server; it reads JSON-RPC requests from stdin\n",
    "                 and writes responses to stdout until stdin closes (EOF).\n",
    "                 This is the normal, correct behavior for an MCP stdio\n",
    "                 server — it is not supposed to be interactive.\n",
  ])

-- `medaka mcp`: the MCP (Model Context Protocol) stdio server.  Mirrors
-- runLspCmd exactly — load MEDAKA_ROOT/stdlib/{runtime,core}.mdk and hand the
-- prelude sources to the tools.mcp entry point (they're threaded through so the
-- tools added by later issues can run the compiler pipeline).  Same `<IO>`
-- effect row as runLspCmd (the `Mut`/`Panic` class the issue cited was cut
-- 2026-07-14 — effects are capabilities only).
--
-- #299: argv used to be discarded (`runMcpCmd _ = ...`), so `--help`/`-h`/any
-- bogus arg silently fell into the JSON-RPC read loop — which blocks on stdin
-- forever if stdin is an open terminal. Blocking on stdin with NO args is
-- correct (that's the actual protocol); only an explicit/unknown arg needs
-- handling before the server starts.
runMcpCmd : List String -> <IO> Unit
runMcpCmd [] = runMcpServerFromEnv ()
runMcpCmd ("--help"::_) =
  let _ = mcpUsage ()
  exit 0
runMcpCmd ("-h"::_) =
  let _ = mcpUsage ()
  exit 0
runMcpCmd (bad::_) =
  let _ = ePutStrLn ("medaka mcp: unknown argument '" ++ bad ++ "' (mcp takes no arguments; try 'medaka mcp --help')")
  exit 1

runMcpServerFromEnv : Unit -> <IO> Unit
runMcpServerFromEnv _ =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  let stdlibDir = root ++ "/stdlib"
  match readPreludeFile rtPath
    Err msg =>
      let _ = ePutStrLn msg
      exit 1
    Ok rsrc => match readPreludeFile corePath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok csrc => runMcpServer rsrc csrc stdlibDir sourceStalenessVerdict
# DESUGAR
(DUse false (UseGroup ("tools" "check") ((mem "runCheck" false) (mem "checkHasErrors" false) (mem "runCheckModules" false))))
(DUse false (UseGroup ("tools" "snapshot") ((mem "runSnapshotWorker" false) (mem "runSnapshotSupervisor" false) (mem "parseStages" false) (mem "SnapMode" true))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "gate_cmd") ((mem "gateHelpText" false) (mem "runGateCmd" false))))
(DUse false (UseGroup ("tools" "new_cmd") ((mem "newProject" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "BuildResult" false) (mem "BuildOk" false) (mem "BuildErr" false) (mem "BuildTarget" false) (mem "TNative" false) (mem "TWasm" false) (mem "runBuild" false) (mem "emitRtObj" false) (mem "emitPreludeObj" false) (mem "envOr" false) (mem "defaultMedakaRoot" false) (mem "readPreludeFile" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinNl" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "endsWith" false) (mem "anyList" false) (mem "filterList" false) (mem "contains" false) (mem "sortUniqS" false) (mem "schemeLineName" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false) (mem "joinPath" false))))
(DUse false (UseGroup ("support" "timer") ((mem "perfEnabled" false) (mem "now" false) (mem "emitPhase" false) (mem "emitTotal" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" false) (mem "LetBind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseWithPositions" false) (mem "parseWithPositionsLocated" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "Positions" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "resolveModulesToHumaneByPath" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" false) (mem "LoadMsg" false) (mem "LoadParseFailed" false) (mem "loadProgramFilesLocatedE" false) (mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false) (mem "entrySearchRoots" false) (mem "projectTrustedMods" false) (mem "stdlibOwnership" false) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false) (mem "availableModulesText" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeProject" false) (mem "analyzeLocated" false) (mem "analyzeLocatedG" false) (mem "ppDiagCli" false) (mem "ppDiagCliSrc" false) (mem "ppDiagCliLines" false) (mem "srcLinesArr" false) (mem "Diag" true) (mem "Severity" true) (mem "SevError" false) (mem "cjPosition" false) (mem "cjRange" false) (mem "cjRangeOfLoc" false) (mem "cjDiagnostic" false) (mem "cjFileEntry" false) (mem "cjAllToJson" false) (mem "readDiagSrc" false) (mem "parseErrCode" false) (mem "parseErrHelpFix" false) (mem "codeKind" false) (mem "optField" false) (mem "cjFixJson" false) (mem "mkDiag" false) (mem "checkJsonFile" false) (mem "readFileSafe" false) (mem "diagIsError" false) (mem "findMainFunDef" false) (mem "mainBodyLoc" false) (mem "mainArityMsg" false) (mem "mainNonUnitMsg" false) (mem "mainArityWarning" false) (mem "mainNonUnitWarning" false) (mem "mainShapeWarnings" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "JNull" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateModules" false) (mem "resetTypeErrorsSticky" false) (mem "hadTypeErrors" false) (mem "mainTypeIsAsync" false) (mem "mainTypeIsUnit" false) (mem "setStdlibOwnership" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "evalModulesOutputRun" false) (mem "evalModulesOutputAsync" false) (mem "currentEvalFile" false) (mem "modulePathMap" false) (mem "runJsonMode" false) (mem "pendingRunDiags" false) (mem "progArgsRef" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTest" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Engine" true))))
(DUse false (UseGroup ("tools" "repl") ((mem "initSession" false) (mem "replLoop" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "runServer" false))))
(DUse false (UseGroup ("tools" "mcp") ((mem "runMcpServer" false))))
(DUse false (UseGroup ("tools" "doc") ((mem "runDoc" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "allRules" false) (mem "lintProgram" false) (mem "applySuppressions" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMultiDirs" false) (mem "collectDirectives" false) (mem "findingToDiag" false) (mem "Finding" false) (mem "Directive" false) (mem "applyFixes" false) (mem "runCrossFileRules" false) (mem "runCrossFileRulesFromOccs" false) (mem "crossFileCacheSound" false) (mem "fileDupOccs" false) (mem "parseLintFlagList" false) (mem "applyFindingFilters" false) (mem "applyFindingDeny" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "splitLintNames" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "LintEntry" true) (mem "contentHashOf" false) (mem "ruleSetStamp" false) (mem "cacheDirOf" false) (mem "loadEntry" false) (mem "storeEntries" false))))
(DUse false (UseGroup ("tools" "codemod") ((mem "findCodemod" false) (mem "codemodMk" false) (mem "codemodWarnDecls" false) (mem "codemodListing" false) (mem "codemodSource" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "runCheckPolicy" false) (mem "PolicyArgs" true) (mem "parsePolicyArgs" false) (mem "PolicyOutcome" true) (mem "runManifest" false) (mem "parseManifestArgs" false) (mem "ManifestArgs" true))))
(DTypeSig false "medakaVersion" (TyCon "String"))
(DFunDef false "medakaVersion" () (ELit (LString "0.1.0-preview")))
(DTypeSig false "printVersion" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printVersion" (PWild) (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "medaka ")) (EVar "medakaVersion"))))
(DTypeSig false "liveSourceFingerprint" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "liveSourceFingerprint" ((PVar "root")) (EBlock (DoLet false false (PVar "script") (EApp (EVar "stringConcat") (EListLit (ELit (LString "command -v perl >/dev/null 2>&1 || exit 7; cd \"")) (EVar "root") (ELit (LString "\" && find compiler -name '*.mdk' -print | LC_ALL=C sort")) (ELit (LString " | perl -ne 'chomp; print \"$_\\n\"; open F,\"<\",$_ or next; local $/; my $c=<F>; print $c if defined $c; close F' 2>/dev/null")) (ELit (LString " | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif command -v shasum >/dev/null 2>&1; then shasum -a 256; else cksum; fi; }")) (ELit (LString " | cut -d' ' -f1"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EVar "script"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "h") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "h") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "h")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "sourceStalenessVerdict" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sourceStalenessVerdict" (PWild) (EBlock (DoLet false false (PVar "baked") (EApp (EVar "buildFingerprint") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "baked") (ELit (LString ""))) (EVar "None") (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "compilerDir"))) (EVar "None") (EMatch (EApp (EVar "liveSourceFingerprint") (EVar "root")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "live")) () (EIf (EBinOp "==" (EVar "live") (EVar "baked")) (EVar "None") (EApp (EVar "Some") (EVar "compilerDir"))))))))))))
(DTypeSig false "checkSourceStaleness" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "checkSourceStaleness" (PWild) (EMatch (EApp (EVar "sourceStalenessVerdict") (ELit LUnit)) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "compilerDir")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EBinOp "++" (ELit (LString "warning: this ./medaka was built from compiler source that differs from ")) (EVar "compilerDir")) (ELit (LString " — it may be stale; rebuild with 'make medaka'.")))) (DoExpr (EIf (EBinOp "/=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_STRICT"))) (ELit (LString ""))) (ELit (LString ""))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EApp (EVar "ePutStrLn") (EVar "msg"))))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false PWild (EApp (EVar "checkSourceStaleness") (ELit LUnit))) (DoExpr (EApp (EVar "runCli") (ELit LUnit)))))
(DTypeSig false "runCli" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCli" (PWild) (EMatch (EApp (EVar "args") (ELit LUnit)) (arm (PList) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "-h")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "-v")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "check")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "checkHelpText")) (EVar "runCheckCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "fmt")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "fmtHelpText")) (EVar "runFmtCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "new")) (PVar "rest")) () (EApp (EVar "runNewCmd") (EVar "rest"))) (arm (PCons (PLit (LString "build")) (PVar "rest")) () (EApp (EVar "runBuildCmd") (EVar "rest"))) (arm (PCons (PLit (LString "run")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "runHelpText")) (EVar "runRunCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "test")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "testHelpText")) (EVar "runTestCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "snapshot")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "snapshotHelpText")) (EVar "runSnapshotCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "doc")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "docHelpText")) (EVar "runDocCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "lint")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "lintHelpText")) (EVar "runLintCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "codemod")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "codemodHelpText")) (EVar "runCodemodCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "check-policy")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "checkPolicyHelpText")) (EVar "runCheckPolicyCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "manifest")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "manifestHelpText")) (EVar "runManifestCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "gate")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "gateHelpText")) (EVar "runGateCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "repl")) (PVar "rest")) () (EApp (EVar "runReplCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lsp")) (PVar "rest")) () (EApp (EVar "runLspCmd") (EVar "rest"))) (arm (PCons (PLit (LString "mcp")) (PVar "rest")) () (EApp (EVar "runMcpCmd") (EVar "rest"))) (arm (PCons (PVar "sub") PWild) () (EApp (EVar "notYet") (EVar "sub")))))
(DTypeSig false "dispatchSub" (TyFun (TyCon "String") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "dispatchSub" ((PVar "help") PWild (PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "help"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "dispatchSub" ((PVar "help") PWild (PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "help"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "dispatchSub" (PWild (PVar "run") (PVar "rest")) (EApp (EVar "run") (EVar "rest")))
(DTypeSig false "usage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "usage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka. A functional language compiler\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka                    Show this message\n")) (ELit (LString "  medaka run [--release] <file.mdk>   Type-check and run a program\n")) (ELit (LString "  medaka build <file.mdk> [-o <out>] [--keep-ir]  Compile to a native binary (LLVM + clang)\n")) (ELit (LString "  medaka check [--json] <file.mdk>    Type-check without running\n")) (ELit (LString "  medaka test [--native | --engines eval,native] [file.mdk]    Run doctests + prop tests (--native runs doctests through a compiled native binary INSTEAD of the interpreter; --engines runs the listed set, exit is the AND)\n")) (ELit (LString "  medaka doc [file.mdk]     Generate Markdown documentation\n")) (ELit (LString "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --cache, --disable/--only/--deny=<rules,...>)\n")) (ELit (LString "  medaka codemod <name> [flags] [paths...]  Apply a named source-preserving AST transform (--write/--stdout)\n")) (ELit (LString "  medaka snapshot [--check|--new|--bless] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n")) (ELit (LString "  medaka fmt [paths...]     Report unformatted files (default; use --write to rewrite in place)\n")) (ELit (LString "  medaka new <name>         Scaffold a new project directory\n")) (ELit (LString "  medaka repl               Start an interactive REPL (reads stdin until EOF or :quit)\n")) (ELit (LString "  medaka lsp                Run the language server over stdio\n")) (ELit (LString "  medaka mcp                Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]  Check a plugin's inferred effects against an allow-list\n")) (ELit (LString "  medaka manifest <file.mdk> [--fn name]  Emit the verified capability manifest as TOML\n")) (ELit (LString "  medaka gate list [<selector>...] [--json]  Query the gate registry (test/gates.toml)\n")) (ELit (LString "  medaka gate run [<selector>...] [--dry-run]  Run the selected gates\n")) (ELit (LString "  medaka help               Show this message\n")) (ELit (LString "  medaka --version          Show the compiler version\n"))))))
(DTypeSig false "notYet" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "notYet" ((PVar "sub")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka: subcommand '")) (EVar "sub")) (ELit (LString "' not yet in native CLI"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "ppParseError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "ppParseError" ((PVar "src") (PVar "file") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EApp (EVar "parseErrorCol") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "h") (PVar "fx")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "h")) (EVar "fx"))))))
(DTypeSig false "checkHelpText" (TyCon "String"))
(DFunDef false "checkHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka check — Type-check a file without running it\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka check [--json] [--types] [--allow-internal] <file.mdk>\n")) (ELit (LString "\n")) (ELit (LString "  --json            emit the {\"files\":[...]} structured-diagnostics\n")) (ELit (LString "                    envelope instead of human text\n")) (ELit (LString "  --types           show the full inferred-scheme dump, prelude included\n")) (ELit (LString "                    (default: only your own top-level bindings)\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")))))
(DTypeSig false "runCheckCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "typesMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--types"))) (EVar "argv"))) (DoLet false false (PVar "argv2") (EApp (EVar "dropFlags") (EVar "argv"))) (DoExpr (EMatch (EVar "argv2") (arm (PList (PVar "target")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EApp (EVar "runCheckJsonCmd") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EVar "map") (EVar "dropModPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false PWild (EApp (EApp (EVar "setStdlibOwnership") (EVar "flatStdlib")) (EVar "ownedStdlib"))) (DoLet false false (PVar "perfTLoad") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "load"))) (EBinOp "-" (EVar "perfTLoad") (EVar "perfT0"))) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRoute") (EVar "typesMode")) (EVar "allowInternal")) (EVar "trusted")) (EVar "pathMap")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "mods"))) (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoExpr (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTCheck") (EVar "perfT0"))))))))))))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check [--json] [--types] [--allow-internal] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DTypeSig false "moduleLoadErrText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "e"))) (EApp (EApp (EApp (EVar "ppParseError") (EVar "msrc")) (EVar "mpath")) (EVar "e")))
(DFunDef false "moduleLoadErrText" ((PVar "tsrc") (PVar "target") (PVar "stdlibDir") (PCon "LoadMsg" (PVar "lmsg"))) (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EVar "lmsg") (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "tsrc"))) (arm (PCon "None") () (EVar "msg")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "msg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))))))
(DTypeSig false "locatedProjectErrors" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "locatedProjectErrors" ((PVar "allowInternal") (PVar "trusted") (PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EApp (EVar "errTextOf") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedProjectDiags") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))))
(DTypeSig false "errTextOf" (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "errTextOf" ((PTuple (PVar "errText") PWild PWild)) (EVar "errText"))
(DTypeSig false "locatedProjectDiags" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Int"))))))))))
(DFunDef false "locatedProjectDiags" ((PVar "allowInternal") (PVar "trusted") (PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "allowInternal")) (EVar "trusted")) (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EVar "results"))) (DoExpr (ETuple (EApp (EVar "joinedOrNone") (EApp (EApp (EVar "flatMap") (EVar "renderTripleErrors")) (EVar "triples"))) (EApp (EApp (EVar "map") (EVar "cohWarnsOfTriple")) (EVar "triples")) (EApp (EVar "length") (EApp (EApp (EVar "flatMap") (EVar "hiddenWarnsOfTriple")) (EApp (EVar "dropEntryTriple") (EVar "triples"))))))))
(DTypeSig false "cohWarnsOfTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "cohWarnsOfTriple" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (ETuple (EVar "path") (EVar "src") (EApp (EApp (EVar "filter") (EVar "isCoherenceWarn")) (EVar "diags"))))
(DTypeSig false "hiddenWarnsOfTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "Diag"))))
(DFunDef false "hiddenWarnsOfTriple" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EVar "filter") (EVar "isHiddenNonEntryWarn")) (EVar "diags")))
(DTypeSig false "isHiddenNonEntryWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isHiddenNonEntryWarn" ((PVar "d")) (EBinOp "&&" (EApp (EVar "isDiagWarn") (EVar "d")) (EApp (EVar "not") (EApp (EVar "isCoherenceWarn") (EVar "d")))))
(DTypeSig false "joinedOrNone" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "joinedOrNone" ((PList)) (EVar "None"))
(DFunDef false "joinedOrNone" ((PVar "ls")) (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "ls"))))
(DTypeSig false "renderTripleErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EVar "errs")))))))
(DTypeSig false "renderTripleWarnings" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleWarnings" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EBlock (DoLet false false (PVar "ws") (EApp (EApp (EVar "filter") (EVar "isDiagWarn")) (EVar "diags"))) (DoExpr (EMatch (EVar "ws") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EVar "ws")))))))
(DTypeSig false "locatedOrGeneric" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))))))
(DFunDef false "locatedOrGeneric" ((PVar "allowInternal") (PVar "trusted") (PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: type error in ")) (EVar "target")) (ELit (LString ", detected during elaboration (the run/build type pass); no located"))) (ELit (LString " diagnostic is available for it, and `medaka check` may not report this"))) (ELit (LString " program at all — see issue #1812"))))))
(DTypeSig false "checkRoute" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Unit")))))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") PWild PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") (PVar "decls")))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "mid")) (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false (PVar "warns") (EApp (EApp (EVar "filter") (EVar "isDiagWarn")) (EVar "diags"))) (DoLet false false (PVar "dump") (EApp (EVar "stripWarningLines") (EApp (EApp (EApp (EVar "runCheck") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoLet false false (PVar "filtered") (EApp (EApp (EVar "userSchemeLines") (EVar "decls")) (EVar "dump"))) (DoLet false false (PVar "report") (EIf (EVar "typesMode") (EVar "dump") (EVar "filtered"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "report"))) (DoLet false false PWild (EIf (EVar "typesMode") (ELit LUnit) (EApp (EVar "putStrLn") (EApp (EApp (EVar "checkOkLine") (EVar "target")) (EVar "filtered"))))) (DoLet false false (PVar "mainWarns") (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "decls"))))) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EBinOp "++" (EVar "warns") (EVar "mainWarns")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") (PVar "pathMap") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneByPath") (EVar "pathMap")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedProjectDiags") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "errText"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PTuple (PCon "None") (PVar "projWarns") (PVar "hiddenCount")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EApp (EApp (EApp (EApp (EVar "runCheckModules") (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD")))) (DoLet false false PWild (EApp (EVar "emitWarningLines") (EApp (EApp (EVar "flatMap") (EVar "renderTripleWarnings")) (EApp (EVar "trimEntryTriple") (EVar "projWarns"))))) (DoLet false false PWild (EApp (EVar "emitHiddenDiagNote") (EVar "hiddenCount"))) (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple (PVar "emid") (PVar "edecls"))) () (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EVar "rtD")) (EVar "coreD")) (EVar "modsD")) (EVar "edecls"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EVar "mainWarns"))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DTypeSig false "lastModPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lastModPair" ((PList)) (EVar "None"))
(DFunDef false "lastModPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "lastModPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModPair") (EVar "rest")))
(DTypeSig false "dropFlags" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropFlags" ((PList)) (EListLit))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--json")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--release")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--allow-internal")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--types")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropFlags") (EVar "rest"))))
(DTypeSig false "hasFlag" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "hasFlag" (PWild (PList)) (EVar "False"))
(DFunDef false "hasFlag" ((PVar "flag") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "flag")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "hasFlag") (EVar "flag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runCheckJsonCmd" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runCheckJsonCmd" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjFileNotFoundJson") (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir"))) (DoLet false false PWild (EApp (EVar "println") (EVar "json"))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))
(DTypeSig false "cjBuildFailedJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "cjBuildFailedJson" ((PVar "target") (PVar "msg")) (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (ELit (LString "")) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-BUILD-FAILED"))) (EVar "msg")) (EVar "None")) (EVar "None")) (EVar "None")))))))
(DTypeSig false "runBuildJsonCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "runBuildJsonCmd" ((PVar "argv") (PVar "allowInternal") (PVar "root") (PVar "stdlibDir") (PVar "input") (PVar "outOpt") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "input")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjFileNotFoundJson") (EVar "input")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (EVar "msg")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (EVar "msg")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "input")) (EVar "stdlibDir"))) (DoExpr (EIf (EVar "hasErr") (EBlock (DoLet false false PWild (EApp (EVar "println") (EVar "json"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "keepIrCli") (EApp (EApp (EVar "hasFlag") (ELit (LString "--keep-ir"))) (EVar "argv"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "input")) (EVar "outPath")) (EVar "keepIrCli")) (arm (PCon "BuildOk" PWild) () (EApp (EVar "println") (EVar "json"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (EVar "msg")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))))))))))))))
(DTypeSig false "cjFileNotFoundJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "cjFileNotFoundJson" ((PVar "target") (PVar "err")) (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read file '")) (EApp (EVar "display") (EVar "target"))) (ELit (LString "': "))) (EApp (EVar "display") (EVar "err"))) (ELit (LString "")))) (DoLet false false (PVar "diagJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (ELit (LString "R-FILE-NOT-FOUND")))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "resolve")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "range")) (EVar "JNull")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka"))))))) (DoLet false false (PVar "filesJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "target"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EListLit (EVar "diagJson"))))))) (DoExpr (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "jArray") (EListLit (EVar "filesJson"))))))))))
(DTypeSig false "isDiagError" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isDiagError" ((PCon "Diag" (PCon "SevError") PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isDiagError" (PWild) (EVar "False"))
(DTypeSig false "isDiagWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isDiagWarn" ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isDiagError") (EVar "d"))))
(DTypeSig false "coherenceWarnCode" (TyCon "String"))
(DFunDef false "coherenceWarnCode" () (ELit (LString "W-INCOMPARABLE-IMPLS")))
(DTypeSig false "runBuildWarnCodes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "runBuildWarnCodes" () (EListLit (EVar "coherenceWarnCode") (ELit (LString "W-PRELUDE-METHOD-SHADOW"))))
(DTypeSig false "isCoherenceWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isCoherenceWarn" ((PCon "Diag" (PCon "SevWarning") (PVar "c") PWild PWild PWild PWild)) (EApp (EApp (EVar "contains") (EVar "c")) (EVar "runBuildWarnCodes")))
(DFunDef false "isCoherenceWarn" (PWild) (EVar "False"))
(DTypeSig false "stripWarningLines" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripWarningLines" ((PVar "s")) (EApp (EVar "joinNl") (EApp (EApp (EVar "filter") (ELam ((PVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "Warning: "))) (EVar "l"))))) (EApp (EVar "splitNl") (EVar "s")))))
(DTypeSig false "userSchemeLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "userSchemeLines" ((PVar "decls") (PVar "report")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "omFromNames") (EApp (EVar "topLevelNames") (EVar "decls"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "joinNl") (EApp (EApp (EVar "filter") (EApp (EVar "namesUserBinding") (EVar "names"))) (EApp (EVar "splitNl") (EVar "report")))))))
(DTypeSig false "checkOkLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "checkOkLine" ((PVar "target") (PVar "filtered")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "length") (EApp (EApp (EVar "filter") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitNl") (EVar "filtered"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "-- ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": ok ("))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " declaration(s) checked, 0 errors)"))))))
(DTypeSig false "namesUserBinding" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "namesUserBinding" ((PVar "names") (PVar "l")) (EMatch (EApp (EVar "schemeLineName") (EVar "l")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "topLevelNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topLevelNames" ((PList)) (EListLit))
(DFunDef false "topLevelNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "topLevelNames") (EListLit (EVar "d"))) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "topLevelNames") (EVar "rest")))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "emitLocatedWarnings" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitLocatedWarnings" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "emitLocatedWarnings" ((PVar "src") (PVar "file") (PVar "ws")) (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "file"))) (EVar "ws")))))
(DTypeSig false "emitWarningLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emitWarningLines" ((PList)) (ELit LUnit))
(DFunDef false "emitWarningLines" ((PVar "ls")) (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EVar "ls"))))
(DTypeSig false "emitHiddenDiagNote" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emitHiddenDiagNote" ((PLit (LInt 0))) (ELit LUnit))
(DFunDef false "emitHiddenDiagNote" ((PVar "n")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " further diagnostic(s) in imported modules; rerun with --json to see them")))))
(DTypeSig false "cohWarnTriples" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "cohWarnTriples" ((PVar "src") (PVar "file") (PVar "diags")) (EMatch (EApp (EApp (EVar "filter") (EVar "isCoherenceWarn")) (EVar "diags")) (arm (PList) () (EListLit)) (arm (PVar "ws") () (EListLit (ETuple (EVar "file") (EVar "src") (EVar "ws"))))))
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
(DFunDef false "onTypecheckWarnChannel" ((PCon "Diag" PWild (PVar "c") PWild PWild PWild PWild)) (EBinOp "==" (EVar "c") (EVar "coherenceWarnCode")))
(DTypeSig false "tripleHasDiags" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "tripleHasDiags" ((PTuple PWild PWild (PList))) (EVar "False"))
(DFunDef false "tripleHasDiags" (PWild) (EVar "True"))
(DData Private "FmtMode" () ((variant "FmtWrite" (ConPos)) (variant "FmtStdout" (ConPos)) (variant "FmtCheck" (ConPos))) ())
(DTypeSig false "fmtHelpText" (TyCon "String"))
(DFunDef false "fmtHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka fmt — Format .mdk file(s)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka fmt [--check | --stdout | --write] <path>...\n")) (ELit (LString "\n")) (ELit (LString "Read-only unless --write is given.\n")) (ELit (LString "\n")) (ELit (LString "  (default)    same as --check: reports files that are not formatted\n")) (ELit (LString "               (exit 1 if any); prints nothing when already formatted.\n")) (ELit (LString "               Never writes.\n")) (ELit (LString "  --check      explicit form of the default\n")) (ELit (LString "  --stdout     print the formatted result to stdout (single file only);\n")) (ELit (LString "               never writes\n")) (ELit (LString "  --write, -w  rewrite the file(s) in place and print a one-line summary\n")) (ELit (LString "               (\"formatted N file(s)\" / \"already formatted\")\n")) (ELit (LString "\n")) (ELit (LString "A path may be a file or a directory (recursively expanded; dotfiles and\n")) (ELit (LString "dot-dirs are skipped).\n")))))
(DTypeSig false "runFmtCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runFmtCmd" ((PVar "argv")) (EMatch (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "argv")) (EVar "FmtCheck")) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple PWild (PList))) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka fmt [--check | --stdout | --write] <path>...")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PList (PVar "target")))) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "fmtOne") (EVar "mode")) (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EListLit (EVar "target")))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "targets"))) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EVar "targets")))))
(DTypeSig false "fmtManyTargets" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtManyTargets" ((PCon "FmtStdout") PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DFunDef false "fmtManyTargets" ((PVar "mode") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: no .mdk files found")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm PWild () (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "changed")) (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "files")) (ETuple (EVar "False") (ELit (LInt 0))))) (DoLet false false PWild (EMatch (EVar "mode") (arm (PCon "FmtWrite") () (EApp (EVar "putStrLn") (EApp (EVar "fmtWriteSummaryLine") (EVar "changed")))) (arm PWild () (ELit LUnit)))) (DoExpr (EIf (EVar "hadErr") (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "fmtFilesGo" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Bool") (TyCon "Int")) (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyCon "Int")))))))
(DFunDef false "fmtFilesGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fmtFilesGo" ((PVar "mode") (PCons (PVar "f") (PVar "rest")) (PTuple (PVar "errAcc") (PVar "changedAcc"))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "changed")) (EApp (EApp (EVar "fmtOneReport") (EVar "mode")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "rest")) (ETuple (EBinOp "||" (EVar "errAcc") (EVar "hadErr")) (EBinOp "+" (EVar "changedAcc") (EIf (EVar "changed") (ELit (LInt 1)) (ELit (LInt 0)))))))))
(DTypeSig false "fmtWriteSummaryLine" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "fmtWriteSummaryLine" ((PLit (LInt 0))) (ELit (LString "already formatted")))
(DFunDef false "fmtWriteSummaryLine" ((PLit (LInt 1))) (ELit (LString "formatted 1 file")))
(DFunDef false "fmtWriteSummaryLine" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "formatted ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " files"))))
(DTypeSig false "fmtOneReport" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "fmtOneReport" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "formatted"))) (DoExpr (ETuple (EVar "False") (EVar "False"))))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ETuple (EVar "False") (EVar "False")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (ETuple (EVar "True") (EVar "False")))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ETuple (EVar "False") (EVar "False")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" PWild) () (ETuple (EVar "False") (EVar "True"))))))))))))))
(DTypeSig false "parseFmtArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "FmtMode") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "parseFmtArgs" ((PList) (PVar "mode") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "acc")))))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--check")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtCheck")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtStdout")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "-w")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PVar "x") (PVar "rest")) (PVar "mode") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "x")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (ELit (LString "medaka fmt: unknown flag: ")) (EVar "x"))) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "mode")) (EBinOp "::" (EVar "x") (EVar "acc")))))
(DTypeSig false "fmtOne" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtOne" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EApp (EVar "putStr") (EVar "formatted"))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EApp (EVar "putStrLn") (ELit (LString "already formatted"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStrLn") (ELit (LString "formatted 1 file")))))))))))))))
(DData Private "CodeMode" () ((variant "CmDry" (ConPos)) (variant "CmWrite" (ConPos)) (variant "CmStdout" (ConPos))) ())
(DTypeSig false "codemodHelpText" (TyCon "String"))
(DFunDef false "codemodHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka codemod — Apply a named source-preserving AST transform\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka codemod <name> [flags] [--write|--stdout] <paths...>\n")) (ELit (LString "\n")) (ELit (LString "  (default)  dry-run: prints \"would rewrite: <file>\" per changed file,\n")) (ELit (LString "             exits 1 if any file would change. Never writes.\n")) (ELit (LString "  --write    rewrite only the files that actually change\n")) (ELit (LString "  --stdout   print one file's result (single file only)\n")) (ELit (LString "\n")) (ELit (LString "Any other --flag consumes the next token as its value, passed to the\n")) (ELit (LString "named codemod. Run `medaka codemod` with no arguments to list the\n")) (ELit (LString "available codemods.\n")) (ELit (LString "\n")) (ELit (LString "NOTE: `--help`/`-h` is only recognized in the FIRST position — as\n")) (ELit (LString "`medaka codemod --help`, before a codemod name. `medaka codemod <name>\n")) (ELit (LString "--help` is NOT special-cased (it is a codemod flag) and codemod-specific\n")) (ELit (LString "help does not exist yet.\n")))))
(DTypeSig false "runCodemodCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCodemodCmd" ((PList)) (EApp (EVar "listCodemodsAndExit") (ELit LUnit)))
(DFunDef false "runCodemodCmd" ((PCons (PVar "name") (PVar "rest"))) (EMatch (EApp (EVar "findCodemod") (EVar "name")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: unknown codemod '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "'"))))) (DoExpr (EApp (EVar "listCodemodsAndExit") (ELit LUnit))))) (arm (PCon "Some" (PVar "cm")) () (EMatch (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmDry")) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "cargs") (PVar "targets"))) () (EMatch (EApp (EApp (EVar "codemodMk") (EVar "cm")) (EVar "cargs")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "xf")) () (EBlock (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka codemod: no .mdk files found")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm PWild () (EMatch (EVar "mode") (arm (PCon "CmStdout") () (EMatch (EVar "files") (arm (PList (PVar "one")) () (EApp (EApp (EApp (EVar "codemodStdout") (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "one"))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka codemod: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))))) (arm PWild () (EIf (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))))))))
(DTypeSig false "listCodemodsAndExit" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "listCodemodsAndExit" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "Usage: medaka codemod <name> [flags] [--write|--stdout] <paths...>")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "Available codemods:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "codemodListing"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DTypeSig false "splitCodemodArgv" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CodeMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "CodeMode") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "splitCodemodArgv" ((PList) (PVar "mode") (PVar "cargs") (PVar "paths")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "cargs")) (EApp (EVar "reverseL") (EVar "paths")))))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmWrite")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmStdout")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PVar "tok") (PVar "rest")) (PVar "mode") (PVar "cargs") (PVar "paths")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "tok")) (EMatch (EVar "rest") (arm (PCons (PVar "v") (PVar "rest2")) () (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest2")) (EVar "mode")) (EBinOp "::" (EVar "v") (EBinOp "::" (EVar "tok") (EVar "cargs")))) (EVar "paths"))) (arm (PList) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: flag '")) (EApp (EVar "display") (EVar "tok"))) (ELit (LString "' requires a value")))))) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "mode")) (EVar "cargs")) (EBinOp "::" (EVar "tok") (EVar "paths")))))
(DTypeSig false "codemodStdout" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "codemodStdout" ((PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EApp (EVar "putStr") (EVar "src"))) (arm (PCon "Some" (PVar "out")) () (EApp (EVar "putStr") (EVar "out")))))))))))
(DTypeSig false "codemodFilesGo" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "codemodFilesGo" (PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "codemodFilesGo" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "signal") (EApp (EApp (EApp (EApp (EVar "codemodOneReport") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "signal"))))))
(DTypeSig false "codemodOneReport" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "codemodOneReport" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "out")) () (EMatch (EVar "mode") (arm (PCon "CmWrite") () (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "out")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EVar "False")))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "would rewrite: ")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ""))))) (DoExpr (EVar "True"))))))))))))))
(DTypeSig false "emitCodemodWarns" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitCodemodWarns" ((PVar "warnFn") (PVar "file") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "decls") PWild) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EApp (EVar "warnFn") (EVar "decls"))))))
(DTypeSig false "emitWarnLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitWarnLines" (PWild (PList)) (ELit LUnit))
(DFunDef false "emitWarnLines" ((PVar "file") (PCons (PVar "w") (PVar "ws"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": warning: "))) (EApp (EVar "display") (EVar "w"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EVar "ws")))))
(DTypeSig false "newUsageLine" (TyCon "String"))
(DFunDef false "newUsageLine" () (ELit (LString "Usage: medaka new <name>")))
(DTypeSig false "runNewCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runNewCmd" ((PList (PVar "arg"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "arg") (ELit (LString "--help"))) (EBinOp "==" (EVar "arg") (ELit (LString "-h")))) (EApp (EVar "putStrLn") (EVar "newUsageLine")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "arg")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "arg")) (ELit (LString "-")))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka new: unknown option '")) (EVar "arg")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "newUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))) (EBlock (DoLet false false (PVar "code") (EApp (EVar "newProject") (EVar "arg"))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (ELit LUnit) (EApp (EVar "exit") (EVar "code"))))))))
(DFunDef false "runNewCmd" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "newUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DTypeSig false "runBuildCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildCmd" ((PVar "argv")) (EIf (EBinOp "||" (EApp (EApp (EVar "hasFlag") (ELit (LString "--help"))) (EVar "argv")) (EApp (EApp (EVar "hasFlag") (ELit (LString "-h"))) (EVar "argv"))) (EApp (EVar "buildUsage") (ELit LUnit)) (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--emit-rt-obj"))) (EVar "argv")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "emitRtObj") (EVar "cc")) (EVar "root")) (EVar "objPath")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EVar "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--emit-prelude-obj"))) (EVar "argv")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "./medaka")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "emitPreludeObj") (EVar "cc")) (EVar "root")) (EVar "medaka")) (EVar "objPath")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EVar "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv")) (EApp (EVar "runBuildJsonEntry") (EVar "argv")) (EApp (EVar "runBuildPlainCmd") (EVar "argv")))))))))
(DTypeSig false "runBuildPlainCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildPlainCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoExpr (EMatch (EApp (EVar "parseBuildArgs") (EVar "argv")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") (PVar "target"))) () (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "input"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "error: no such file: ")) (EVar "input")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "inputAbs") (EVar "input")) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "keepIrCli") (EApp (EApp (EVar "hasFlag") (ELit (LString "--keep-ir"))) (EVar "argv"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "typecheckGate") (EVar "allowInternal")) (EVar "root")) (EVar "inputAbs")) (arm (PCon "TGErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "TGOk" (PVar "gateWarns")) () (EBlock (DoLet false false PWild (EApp (EVar "emitWarningLines") (EVar "gateWarns"))) (DoLet false false (PVar "perfTTc") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "typecheck"))) (EBinOp "-" (EVar "perfTTc") (EVar "perfT0"))) (EVar "input"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")) (arm (PCon "BuildOk" (PVar "msg")) () (EBlock (DoLet false false (PVar "perfTEmit") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "emit"))) (EBinOp "-" (EVar "perfTEmit") (EVar "perfTTc"))) (EVar "input"))) (DoLet false false PWild (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTEmit") (EVar "perfT0")))) (DoExpr (EApp (EVar "println") (EVar "msg"))))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))))))))))))
(DTypeSig false "runBuildJsonEntry" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildJsonEntry" ((PVar "argv")) (EMatch (EApp (EVar "parseBuildArgs") (EVar "argv")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjBuildFailedJson") (ELit (LString ""))) (EVar "msg")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") (PVar "target"))) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildJsonCmd") (EVar "argv")) (EVar "allowInternal")) (EVar "root")) (EVar "stdlibDir")) (EVar "input")) (EVar "outOpt")) (EVar "target")))))))
(DTypeSig false "buildUsage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "buildUsage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>] [--keep-ir] [--allow-internal] [--json]\n")) (ELit (LString "\n")) (ELit (LString "  -o <out>          output path for the binary (default: <file> with its extension dropped)\n")) (ELit (LString "  --target <t>      backend: native (LLVM + clang, default) or wasm (WasmGC + wasm-tools)\n")) (ELit (LString "  --json            emit the {\"files\":[...]} structured-diagnostics envelope (same\n")) (ELit (LString "                    schema as `medaka check --json`) instead of human text; a genuine\n")) (ELit (LString "                    build-stage (emitter/clang) failure carries code R-BUILD-FAILED\n")) (ELit (LString "  --keep-ir         keep the emitted IR (.ll for native, .wat for wasm) at <out>.ll/.wat\n")) (ELit (LString "                    instead of discarding it with the build's scratch directory; the\n")) (ELit (LString "                    kept path is printed. Env var MEDAKA_KEEP_IR=1 does the same for a\n")) (ELit (LString "                    build invoked by something else (e.g. a test harness)\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --emit-rt-obj <p> compile only runtime/medaka_rt.c to a reusable object at <p> (with\n")) (ELit (LString "                    the same flags a normal link uses) and exit; point MEDAKA_RT_OBJ at\n")) (ELit (LString "                    it to skip recompiling the runtime on every subsequent build\n")) (ELit (LString "  --emit-prelude-obj <p>\n")) (ELit (LString "                    compile only stdlib/core.mdk to a reusable object at <p> (with the\n")) (ELit (LString "                    same flags a normal link uses) and exit; point MEDAKA_PRELUDE_OBJ at\n")) (ELit (LString "                    it to skip re-optimising the prelude on every subsequent build.\n")) (ELit (LString "                    Opt-in: separate objects cannot inline the prelude into user code\n")) (ELit (LString "\n")) (ELit (LString "runtime object cache (ON by default):\n")) (ELit (LString "  Every native build links a compiled runtime/medaka_rt.c. Rather than recompile\n")) (ELit (LString "  it each time (~0.76s), build caches the object, keyed on a hash of the .c\n")) (ELit (LString "  source, the C compiler and its version, and the exact compile flags, so a\n")) (ELit (LString "  changed runtime or compiler never reuses a stale object.\n")) (ELit (LString "  Location (first that applies): $MEDAKA_CACHE_DIR, else\n")) (ELit (LString "  $XDG_CACHE_HOME/medaka, else $HOME/.cache/medaka.\n")) (ELit (LString "  MEDAKA_NO_OBJ_CACHE=1  disable the cache; compile medaka_rt.c inline every build\n")) (ELit (LString "  MEDAKA_CACHE_DIR=<d>   put the cache somewhere else (e.g. a per-CI-job scratch dir)\n")) (ELit (LString "  An explicit MEDAKA_RT_OBJ still wins over the cache. Every cache failure is\n")) (ELit (LString "  fail-open: build falls back to the inline compile, never to an error.\n"))))))
(DTypeSig false "defaultOutPath" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "defaultOutPath" ((PCon "TNative") (PVar "input")) (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))))
(DFunDef false "defaultOutPath" ((PCon "TWasm") (PVar "input")) (EBinOp "++" (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))) (ELit (LString ".wasm"))))
(DData Private "TypecheckGate" () ((variant "TGOk" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "TGErr" (ConPos (TyCon "String")))) ())
(DTypeSig false "typecheckGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "TypecheckGate"))))))
(DFunDef false "typecheckGate" ((PVar "allowInternal") (PVar "root") (PVar "input")) (EBlock (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "input"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "input")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "TGErr") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "input")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "input")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EApp (EVar "TGErr") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "input")) (EVar "stdlibDir")) (EVar "lerr")))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EVar "map") (EVar "dropModPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "input")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "input")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false PWild (EApp (EApp (EVar "setStdlibOwnership") (EVar "flatStdlib")) (EVar "ownedStdlib"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckGateRoute") (EVar "allowInternal")) (EVar "trusted")) (EVar "pathMap")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "input")) (EVar "mods")))))))))))))))))
(DTypeSig false "typecheckGateRoute" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "TypecheckGate"))))))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") PWild PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") (PVar "decls")))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "mid")) (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false (PVar "mainWarns") (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "decls"))))) (EVar "decls"))) (DoLet false false (PVar "allWarns") (EBinOp "++" (EApp (EApp (EApp (EVar "cohWarnTriples") (EVar "tsrc")) (EVar "target")) (EVar "diags")) (EApp (EVar "nonEmptyTriples") (EListLit (ETuple (EVar "target") (EVar "tsrc") (EVar "mainWarns")))))) (DoExpr (EApp (EVar "TGOk") (EApp (EApp (EVar "flatMap") (EVar "renderTripleWarnings")) (EVar "allWarns")))))) (arm PWild () (EApp (EVar "TGErr") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs")))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") (PVar "pathMap") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneByPath") (EVar "pathMap")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedProjectDiags") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EApp (EVar "TGErr") (EVar "errText"))) (arm (PTuple (PCon "None") (PVar "projWarns") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EApp (EVar "TGErr") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (arm (PCon "False") () (EBlock (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EMatch (EApp (EVar "mainArityWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EMatch (EApp (EVar "mainNonUnitWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit)))))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "allWarns") (EBinOp "++" (EVar "projWarns") (EApp (EVar "nonEmptyTriples") (EListLit (ETuple (EVar "target") (EVar "tsrc") (EVar "mainWarns")))))) (DoExpr (EApp (EVar "TGOk") (EApp (EApp (EVar "flatMap") (EVar "renderTripleWarnings")) (EVar "allWarns")))))))))))) (arm PWild () (EApp (EVar "TGErr") (EVar "resDiags")))))))
(DTypeSig false "parseBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))
(DFunDef false "parseBuildArgs" ((PVar "argv")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "argv")) (EListLit)) (EVar "None")) (EVar "TNative")))
(DTypeSig false "parseBuildGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget"))))))))
(DFunDef false "parseBuildGo" ((PList) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EVar "finishBuildArgs") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "-o")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EApp (EVar "Some") (EVar "v"))) (EVar "target")))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "-o"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: -o requires an argument"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--target")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") PWild) (EMatch (EApp (EVar "parseTarget") (EVar "v")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PVar "t")) () (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "t")))))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "--target"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: --target requires an argument (native|wasm)"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--allow-internal")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--keep-ir")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--json")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PVar "x") (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DTypeSig false "parseTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))
(DFunDef false "parseTarget" ((PLit (LString "native"))) (EApp (EVar "Ok") (EVar "TNative")))
(DFunDef false "parseTarget" ((PLit (LString "wasm"))) (EApp (EVar "Ok") (EVar "TWasm")))
(DFunDef false "parseTarget" ((PVar "other")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "error: unknown --target '")) (EVar "other")) (ELit (LString "' (expected native|wasm)")))))
(DTypeSig false "finishBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))))
(DFunDef false "finishBuildArgs" ((PList) PWild PWild) (EApp (EVar "Err") (ELit (LString "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>]"))))
(DFunDef false "finishBuildArgs" ((PList (PVar "input")) (PVar "out") (PVar "target")) (EApp (EVar "Ok") (ETuple (EVar "input") (EVar "out") (EVar "target"))))
(DFunDef false "finishBuildArgs" (PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: medaka build takes exactly one input file"))))
(DTypeSig false "finishRunEval" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "finishRunEval" ((PVar "target") (PVar "jsonMode") (PVar "elaborated") (PVar "mods") (PVar "cohWarns")) (EBlock (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EMatch (EApp (EVar "mainArityWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EMatch (EApp (EVar "mainNonUnitWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit)))))) (arm (PCon "None") () (EListLit)))) (DoLet false false PWild (EIf (EVar "jsonMode") (ELit LUnit) (EApp (EVar "emitWarningLines") (EApp (EApp (EVar "flatMap") (EVar "renderTripleWarnings")) (EVar "cohWarns"))))) (DoLet false false PWild (EIf (EVar "jsonMode") (EApp (EApp (EVar "setRef") (EVar "pendingRunDiags")) (EApp (EVar "nonEmptyTriples") (EBinOp "++" (EVar "cohWarns") (EListLit (ETuple (EVar "target") (EApp (EVar "readFileSafe") (EVar "target")) (EVar "mainWarns")))))) (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "mainWarns")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "runJsonMode")) (EVar "jsonMode"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EVar "runProgramOutput") (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated"))))) (DoLet false false PWild (EApp (EVar "flushPendingRunDiags") (EVar "jsonMode"))) (DoExpr (EMatch (EVar "mainWarns") (arm (PList) () (ELit LUnit)) (arm (PCons PWild PWild) () (EApp (EVar "exit") (ELit (LInt 1))))))))
(DTypeSig false "flushPendingRunDiags" (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "flushPendingRunDiags" ((PCon "False")) (ELit LUnit))
(DFunDef false "flushPendingRunDiags" ((PCon "True")) (EMatch (EUnOp "!" (EVar "pendingRunDiags")) (arm (PList) () (ELit LUnit)) (arm (PVar "ts") () (EApp (EVar "ePutStrLn") (EApp (EVar "cjAllToJson") (EVar "ts"))))))
(DTypeSig false "runHelpText" (TyCon "String"))
(DFunDef false "runHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka run — Type-check and run a program (interpreter)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka run [--json] [--allow-internal] [--release] <file.mdk> [args...]\n")) (ELit (LString "\n")) (ELit (LString "  --json            emit the Diag JSON envelope for a compile-time error or\n")) (ELit (LString "                    a runtime panic, instead of human text\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --release         accepted, ignored (no-op for the interpreter path;\n")) (ELit (LString "                    kept for symmetry with `medaka build --release`)\n")) (ELit (LString "\n")) (ELit (LString "Args after <file.mdk> are passed through to the program's own `args`.\n")) (ELit (LString "Inline-eval (`-e <expr>`) is NOT supported — pass a file.\n")))))
(DTypeSig false "runRunCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runRunCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoExpr (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka run [--release] [--json] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") PWild) ((GBool (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "target")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "target")) (ELit (LString "-")))))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "medaka run: unknown flag: ")) (EVar "target")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") (PVar "progArgs")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "progArgsRef")) (EVar "progArgs"))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "parseResult") (EApp (EVar "readFileSafe") (EVar "target"))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EVar "map") (EVar "dropModPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "modulePathMap")) (EVar "pathMap"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false PWild (EApp (EApp (EVar "setStdlibOwnership") (EVar "flatStdlib")) (EVar "ownedStdlib"))) (DoLet false false (PVar "perfTLoad") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "load"))) (EBinOp "-" (EVar "perfTLoad") (EVar "perfT0"))) (EVar "target"))) (DoExpr (EMatch (EVar "modsD") (arm (PList (PTuple (PVar "runMid") PWild)) () (EBlock (DoLet false false (PVar "tsrc") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "runMid")) (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods")) (EApp (EApp (EApp (EVar "cohWarnTriples") (EVar "tsrc")) (EVar "target")) (EVar "diags")))) (DoLet false false (PVar "perfTEval") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "eval"))) (EBinOp "-" (EVar "perfTEval") (EVar "perfTCheck"))) (EVar "target"))) (DoExpr (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTEval") (EVar "perfT0")))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm PWild () (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneByPath") (EVar "pathMap")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedProjectDiags") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "errText"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PTuple (PCon "None") (PVar "projWarns") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "False") () (EBlock (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods")) (EVar "projWarns"))) (DoLet false false (PVar "perfTEval") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "eval"))) (EBinOp "-" (EVar "perfTEval") (EVar "perfTCheck"))) (EVar "target"))) (DoExpr (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTEval") (EVar "perfT0")))))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))))))))))))))))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "p"))))
(DTypeSig false "dropModPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropModPath" ((PTuple (PVar "mid") PWild (PVar "prog"))) (ETuple (EVar "mid") (EVar "prog")))
(DTypeSig false "modIdToPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "modIdToPath" ((PTuple (PVar "mid") (PVar "path") PWild)) (ETuple (EVar "mid") (EVar "path")))
(DTypeSig false "runProgramOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "runProgramOutput" ((PVar "preludeDecls") (PVar "modules")) (EMatch (EApp (EVar "mainTypeIsAsync") (ELit LUnit)) (arm (PCon "True") () (EApp (EApp (EVar "evalModulesOutputAsync") (EVar "preludeDecls")) (EVar "modules"))) (arm (PCon "False") () (EApp (EApp (EVar "evalModulesOutputRun") (EVar "preludeDecls")) (EVar "modules")))))
(DTypeSig false "testHelpText" (TyCon "String"))
(DFunDef false "testHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka test — Run doctests + property tests\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka test [--native | --engines eval,native] [file.mdk | dir]\n")) (ELit (LString "\n")) (ELit (LString "  --native            run doctests through a compiled native binary\n")) (ELit (LString "                      instead of the interpreter (shorthand for\n")) (ELit (LString "                      --engines native)\n")) (ELit (LString "  --engines e1,e2,...  run the listed engine set (known: eval, native);\n")) (ELit (LString "                      exit code is the AND across engines\n")) (ELit (LString "\n")) (ELit (LString "--native and --engines are mutually exclusive. With neither, the default\n")) (ELit (LString "is the interpreter (eval) alone. A file.mdk or dir target is required.\n")))))
(DTypeSig false "runTestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runTestCmd" ((PVar "argv")) (EMatch (EApp (EVar "parseTestEngines") (EVar "argv")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "engines")) () (EMatch (EApp (EVar "testTargets") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka test [--native | --engines eval,native] [file.mdk | dir]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PList (PVar "target")) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "runTestOne") (EVar "engines")) (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "runTestManyTargets") (EVar "engines")) (EListLit (EVar "target")))))) (arm (PVar "targets") () (EApp (EApp (EVar "runTestManyTargets") (EVar "engines")) (EVar "targets")))))))
(DTypeSig false "parseTestEngines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseTestEngines" ((PVar "argv")) (EMatch (ETuple (EApp (EApp (EVar "testFlagValue") (ELit (LString "--engines"))) (EVar "argv")) (EApp (EApp (EVar "hasFlag") (ELit (LString "--native"))) (EVar "argv"))) (arm (PTuple (PCon "Some" PWild) (PCon "True")) () (EApp (EVar "Err") (ELit (LString "--native and --engines are mutually exclusive; --native is shorthand for --engines native")))) (arm (PTuple (PCon "Some" (PVar "spec")) (PCon "False")) () (EApp (EVar "parseEngineList") (EVar "spec"))) (arm (PTuple (PCon "None") (PCon "True")) () (EApp (EVar "Ok") (EListLit (EVar "EngNative")))) (arm (PTuple (PCon "None") (PCon "False")) () (EApp (EVar "Ok") (EListLit (EVar "EngInterp"))))))
(DTypeSig false "parseEngineList" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseEngineList" ((PVar "spec")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EApp (EVar "map") (EVar "stringTrim")) (EApp (EVar "splitLintNames") (EVar "spec"))))) (DoExpr (EMatch (EVar "names") (arm (PList) () (EApp (EVar "Err") (ELit (LString "--engines requires at least one of: eval, native")))) (arm PWild () (EApp (EVar "parseEngineNames") (EVar "names")))))))
(DTypeSig false "parseEngineNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseEngineNames" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "parseEngineNames" ((PCons (PVar "n") (PVar "rest"))) (EMatch (EApp (EVar "engineOfName") (EVar "n")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown engine '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' (known: eval, native)"))))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "e") (EVar "_s")))) (EApp (EVar "parseEngineNames") (EVar "rest"))))))
(DTypeSig false "engineOfName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Engine"))))
(DFunDef false "engineOfName" ((PLit (LString "eval"))) (EApp (EVar "Some") (EVar "EngInterp")))
(DFunDef false "engineOfName" ((PLit (LString "native"))) (EApp (EVar "Some") (EVar "EngNative")))
(DFunDef false "engineOfName" (PWild) (EVar "None"))
(DTypeSig false "testFlagValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "testFlagValue" (PWild (PList)) (EVar "None"))
(DFunDef false "testFlagValue" (PWild (PList PWild)) (EVar "None"))
(DFunDef false "testFlagValue" ((PVar "name") (PCons (PVar "a") (PCons (PVar "v") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "name")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "testFlagValue") (EVar "name")) (EBinOp "::" (EVar "v") (EVar "rest")))))
(DTypeSig false "testTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "testTargets" ((PList)) (EListLit))
(DFunDef false "testTargets" ((PCons (PLit (LString "--engines")) (PCons PWild (PVar "rest")))) (EApp (EVar "testTargets") (EVar "rest")))
(DFunDef false "testTargets" ((PCons (PLit (LString "--native")) (PVar "rest"))) (EApp (EVar "testTargets") (EVar "rest")))
(DFunDef false "testTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "testTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "testTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runTestOne" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runTestOne" ((PVar "engines") (PVar "target")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "target")) (EVar "roots"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig false "runTestManyTargets" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runTestManyTargets" ((PVar "engines") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "medaka test: no .mdk files found")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "testFilesGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "testFilesGo" (PWild PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "testFilesGo" ((PVar "engines") (PVar "rtPath") (PVar "corePath") (PVar "stdlibDir") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "f"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "f")) (EVar "roots"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EApp (EVar "not") (EVar "ok")))))))
(DTypeSig false "docHelpText" (TyCon "String"))
(DFunDef false "docHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka doc — Generate Markdown documentation for a file\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka doc <file.mdk>\n")) (ELit (LString "\n")) (ELit (LString "Prints Markdown for every PUBLIC declaration (with inferred type\n")) (ELit (LString "schemes) in <file.mdk> to stdout. Single-file only.\n")))))
(DTypeSig false "runDocCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runDocCmd" ((PVar "argv")) (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka doc [file.mdk]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") PWild) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runDoc") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target"))))))))))))))
(DTypeSig false "checkPolicyHelpText" (TyCon "String"))
(DFunDef false "checkPolicyHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka check-policy — Check a plugin's inferred effects against an allow-list\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]\n")) (ELit (LString "\n")) (ELit (LString "  --allow L1,L2,...  effect labels the plugin is permitted to use\n")) (ELit (LString "                     (default: Cache,Log)\n")) (ELit (LString "  --fn name          the function whose inferred effect row is checked\n")) (ELit (LString "                     (default: transform)\n")) (ELit (LString "\n")) (ELit (LString "Prints an accept/reject header; on accept, also runs the plugin on a\n")) (ELit (LString "sample request. Exit 0 on accept, 1 on reject.\n")))))
(DTypeSig false "runCheckPolicyCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckPolicyCmd" ((PVar "argv")) (EMatch (EApp (EVar "parsePolicyArgs") (EVar "argv")) (arm (PCon "PolicyArgs" (PCon "None") PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyArgs" (PCon "Some" (PVar "target")) (PVar "allow") (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "runCheckPolicy") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "allow")) (EVar "fn")) (arm (PCon "PolicyReject" (PVar "report")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "report"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyAccept" (PVar "report")) () (EApp (EVar "putStr") (EVar "report")))))))))))))))
(DTypeSig false "manifestHelpText" (TyCon "String"))
(DFunDef false "manifestHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka manifest — Emit a module's verified capability manifest as TOML\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka manifest <file.mdk> [--fn name]\n")) (ELit (LString "\n")) (ELit (LString "  --fn name  the function whose inferred effect row is emitted\n")) (ELit (LString "             (default: main)\n")) (ELit (LString "\n")) (ELit (LString "Prints a [package.capabilities] TOML block: one entry per effect label\n")) (ELit (LString "in the function's inferred effect row (a prefix-param becomes a string\n")) (ELit (LString "value; a Unit/top param becomes `true`).\n")))))
(DTypeSig false "runManifestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runManifestCmd" ((PVar "argv")) (EMatch (EApp (EVar "parseManifestArgs") (EVar "argv")) (arm (PCon "ManifestArgs" (PCon "None") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka manifest <file.mdk> [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "ManifestArgs" (PCon "Some" (PVar "target")) (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runManifest") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "fn"))))))))))))))
(DTypeSig false "lintHelpText" (TyCon "String"))
(DFunDef false "lintHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lint — Lint files/dirs against style rules\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka lint [paths...] [flags]\n")) (ELit (LString "\n")) (ELit (LString "  --fix                 rewrite fixable findings in-place\n")) (ELit (LString "  --json                emit the {\"files\":[...]} structured-diagnostics\n")) (ELit (LString "                       envelope instead of human text (--fix is ignored)\n")) (ELit (LString "  --cache                reuse per-file results for files whose content is\n")) (ELit (LString "                       unchanged (opt-in, like ESLint's --cache)\n")) (ELit (LString "  --disable=r1,r2,...    suppress findings from the named rules\n")) (ELit (LString "  --only=r1,...          keep only findings from the named rules\n")) (ELit (LString "  --deny=r1,...          promote findings from the named rules to error\n")) (ELit (LString "\n")) (ELit (LString "Target resolution: explicit file args are linted in order; a single\n")) (ELit (LString "directory arg lints its top-level .mdk files (not recursive); no args\n")) (ELit (LString "finds the medaka.toml project root and lints its top-level .mdk files.\n")) (ELit (LString "Exit 0 unless a SevError finding exists.\n")))))
(DTypeSig false "runLintCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintCmd" ((PVar "argv")) (EBlock (DoLet false false PWild (EApp (EVar "assertLintFlagsHaveValues") (EVar "argv"))) (DoLet false false (PVar "disableNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--disable="))) (EVar "argv"))) (DoLet false false (PVar "onlyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--only="))) (EVar "argv"))) (DoLet false false (PVar "denyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--deny="))) (EVar "argv"))) (DoLet false false (PVar "fixMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--fix"))) (EVar "argv"))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoLet false false (PVar "fileArgs") (EApp (EVar "lintTargets") (EVar "argv"))) (DoLet false false PWild (EApp (EVar "assertLintTargetsExist") (EVar "fileArgs"))) (DoLet false false (PVar "files") (EApp (EVar "resolveLintTargets") (EVar "fileArgs"))) (DoExpr (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EVar "runLintJsonCmd") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files")) (EBlock (DoLet false false (PVar "multiFile") (EMatch (EVar "files") (arm (PCons PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False")))) (DoLet false false (PVar "cacheCtx") (EApp (EApp (EVar "lintCacheCtx") (EApp (EApp (EVar "hasFlag") (ELit (LString "--cache"))) (EVar "argv"))) (EVar "fixMode"))) (DoLet false false (PTuple (PVar "perFileErr") (PVar "entries") (PVar "parsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "files")) (EVar "False"))) (DoLet false false (PVar "crossErr") (EIf (EApp (EVar "not") (EBinOp "&&" (EVar "multiFile") (EApp (EVar "not") (EVar "fixMode")))) (EVar "False") (EMatch (EVar "cacheCtx") (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "runCrossFileReportCached") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "entries"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "runCrossFileReport") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "parsed")))))) (DoLet false false PWild (EMatch (EVar "cacheCtx") (arm (PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) () (EApp (EApp (EApp (EVar "storeEntries") (EVar "cacheDir")) (EVar "stamp")) (EVar "entries"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EIf (EBinOp "||" (EVar "perFileErr") (EVar "crossErr")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit))))))))
(DTypeSig false "lintCacheCtx" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lintCacheCtx" ((PCon "False") PWild) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "True")) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "False")) (EIf (EApp (EVar "not") (EVar "crossFileCacheSound")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "root") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "canonicalizePath") (ELit (LString "."))))) (DoLet false false (PVar "stamp") (EApp (EVar "ruleSetStamp") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "stamp") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EVar "cacheDirOf") (EVar "root")) (EVar "stamp")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runLintJsonCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "runLintJsonCmd" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "files")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "cjAllToJson") (EVar "triples")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "cjLintTripleHasErr")) (EVar "triples")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))
(DTypeSig false "lintFilesToDiagTriples" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "lintFilesToDiagTriples" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagTriples" ((PVar "disable") (PVar "only") (PVar "deny") (PCons (PVar "f") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "rest"))))
(DTypeSig false "cjLintTripleHasErr" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjLintTripleHasErr" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags")))
(DTypeSig false "runCrossFileReport" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReport" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "parsed")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "parsedToTriple")) (EVar "parsed"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "triples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EVar "map") (EVar "parsedToSrc")) (EVar "parsed"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportCrossFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig false "runCrossFileReportCached" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Bool")))))))
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
(DTypeSig false "lintValueFlags" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "lintValueFlags" () (EListLit (ELit (LString "--disable")) (ELit (LString "--only")) (ELit (LString "--deny"))))
(DTypeSig false "assertLintFlagsHaveValues" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertLintFlagsHaveValues" ((PVar "argv")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EVar "filter") (ELam ((PVar "f")) (EApp (EApp (EVar "contains") (EVar "f")) (EVar "argv")))) (EVar "lintValueFlags"))) (DoExpr (EIf (EBinOp "==" (EVar "bad") (EListLit)) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lint: ")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "bad")) (ELit (LString " require a value in the form --flag=<rule1,rule2,...> (a bare '")) (ELit (LString "--flag <rule>' space-separated form is not supported and would be silently")) (ELit (LString " ignored, so it is rejected instead)")))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "lintTargetExists" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "lintTargetExists" ((PVar "t")) (EMatch (EApp (EVar "listDir") (EVar "t")) (arm (PCon "Ok" PWild) () (EVar "True")) (arm (PCon "Err" PWild) () (EApp (EVar "fileExists") (EVar "t")))))
(DTypeSig false "assertLintTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertLintTargetsExist" ((PList)) (ELit LUnit))
(DFunDef false "assertLintTargetsExist" ((PVar "targets")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EVar "filter") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EVar "lintTargetExists") (EVar "t"))))) (EVar "targets"))) (DoExpr (EIf (EBinOp "==" (EVar "missing") (EListLit)) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: these targets do not exist:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "resolveLintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "resolveLintTargets" ((PList)) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoExpr (EMatch (EApp (EVar "findProjectRoot") (EVar "cwd")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths")))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit)))) (arm (PCon "Some" (PVar "root")) () (EApp (EVar "collectMdkFiles") (EVar "root")))))))
(DFunDef false "resolveLintTargets" ((PVar "targets")) (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets")))
(DTypeSig false "expandLintTarget" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expandLintTarget" ((PVar "target")) (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFiles") (EVar "target"))) (arm (PCon "Err" PWild) () (EListLit (EVar "target")))))
(DTypeSig false "lintPathJoin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "lintPathJoin" ((PVar "dir") (PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "dir")) (EBinOp "++" (EVar "dir") (EVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "collectMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFiles" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: cannot list directory ")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EListLit)))) (arm (PCon "Ok" PWild) () (EApp (EVar "sortUniqS") (EApp (EVar "collectMdkFilesRec") (EVar "dir"))))))
(DTypeSig false "collectMdkFilesRec" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFilesRec" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EApp (EVar "filterNonDot") (EVar "entries"))))))
(DTypeSig false "collectMdkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntries" (PWild (PList)) (EListLit))
(DFunDef false "collectMdkEntries" ((PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "collectMdkEntry") (EVar "dir")) (EVar "name")) (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EVar "rest"))))
(DTypeSig false "collectMdkEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntry" ((PVar "dir") (PVar "name")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "lintPathJoin") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFilesRec") (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EListLit (EVar "full")) (EListLit)))))))
(DTypeSig false "filterNonDot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonDot" ((PList)) (EListLit))
(DFunDef false "filterNonDot" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EApp (EVar "filterNonDot") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EVar "filterNonDot") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lintFilesGo" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))))
(DFunDef false "lintFilesGo" (PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (ETuple (EVar "acc") (EListLit) (EListLit)))
(DFunDef false "lintFilesGo" ((PVar "fixMode") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "cacheCtx") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EIf (EVar "fixMode") (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EApp (EVar "lintOneFileFix") (EVar "onlyNames")) (EVar "disableNames")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "entries") (PVar "parsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileReport") (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "f"))) (DoLet false false (PTuple (PVar "restErr") (PVar "restEntries") (PVar "restParsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr")))) (DoExpr (ETuple (EVar "restErr") (EBinOp "++" (EVar "entries") (EVar "restEntries")) (EBinOp "++" (EVar "parsed") (EVar "restParsed")))))))
(DTypeSig false "lintOneFileReport" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))
(DFunDef false "lintOneFileReport" ((PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "cacheCtx") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (ETuple (EVar "True") (EListLit) (EListLit))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "parsed")) (EApp (EApp (EApp (EVar "lintEntryOf") (EVar "cacheCtx")) (EVar "target")) (EVar "src"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EFieldAccess (EVar "entry") "directives")) (EFieldAccess (EVar "entry") "findings"))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "allFindings"))) (DoLet false false (PVar "srcLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (DoLet false false (PVar "output") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliLines") (EVar "srcLines")) (EVar "target")) (EApp (EVar "findingToDiag") (EVar "f"))))) (EVar "findings")))) (DoLet false false (PVar "hasOutput") (EBinOp ">" (EApp (EVar "stringLength") (EVar "output")) (ELit (LInt 0)))) (DoLet false false PWild (EIf (EBinOp "&&" (EVar "multiFile") (EVar "hasOutput")) (EApp (EVar "putStrLn") (EBinOp "++" (EVar "target") (ELit (LString ":")))) (ELit LUnit))) (DoLet false false PWild (EIf (EVar "hasOutput") (EApp (EVar "putStrLn") (EVar "output")) (ELit LUnit))) (DoExpr (ETuple (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")) (EListLit (EVar "entry")) (EVar "parsed")))))))
(DTypeSig false "lintEntryOf" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "lintEntryOf" ((PCon "None") (PVar "target") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "target")) (EVar "src")) (ELit (LString ""))) (EVar "False"))) (DoExpr (ETuple (EVar "entry") (EListLit (ETuple (EVar "target") (EVar "src") (EVar "pos") (EVar "decls")))))))
(DFunDef false "lintEntryOf" ((PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) (PVar "target") (PVar "src")) (EBlock (DoLet false false (PVar "hash") (EApp (EVar "contentHashOf") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadEntry") (EVar "cacheDir")) (EVar "stamp")) (EVar "target")) (EVar "hash")) (arm (PCon "Some" (PVar "hit")) () (ETuple (EVar "hit") (EListLit))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "entry") PWild PWild) (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "target")) (EVar "src")) (EVar "hash")) (EVar "True"))) (DoExpr (ETuple (EVar "entry") (EListLit)))))))))
(DTypeSig false "lintFileFresh" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "lintFileFresh" ((PVar "target") (PVar "src") (PVar "hash") (PVar "wantOccs")) (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositionsLocated") (EVar "src"))) (DoExpr (ETuple (ERecordCreate "LintEntry" ((fa "path" (EVar "target")) (fa "contentHash" (EVar "hash")) (fa "findings" (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "allRules")) (EVar "target")) (EVar "src")) (EVar "pos")) (EVar "decls"))) (fa "dupOccs" (EIf (EVar "wantOccs") (EApp (EVar "fileDupOccs") (ETuple (EVar "target") (EVar "pos") (EVar "decls"))) (EListLit))) (fa "directives" (EApp (EVar "collectDirectives") (EVar "src"))) (fa "dirty" (EVar "True")))) (EVar "pos") (EVar "decls")))))
(DTypeSig false "lintOneFileFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "lintOneFileFix" ((PVar "onlyNames") (PVar "disableNames") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "newSrc") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "onlyNames")) (EVar "disableNames")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "newSrc") (EVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "fixed 0 finding(s) in ")) (EVar "target")))) (DoExpr (EVar "False"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "target")) (EVar "newSrc")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 2)))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "fixed ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) in "))) (EApp (EVar "display") (EVar "target"))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))))))
(DTypeSig false "lintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lintTargets" ((PList)) (EListLit))
(DFunDef false "lintTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "lintTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "lintTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "assertSnapshotTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertSnapshotTargetsExist" ((PVar "files")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EVar "filter") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "f"))))) (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "missing") (EListLit)) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: these targets do not exist:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "assertBlessIsScoped" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "assertBlessIsScoped" ((PVar "argv") (PVar "targets")) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "hasFlag") (ELit (LString "--bless"))) (EVar "argv"))) (EBinOp "/=" (EVar "targets") (EListLit))) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: --bless requires explicit targets — there is no whole-suite bless.")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  Name what you are approving, e.g.:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "    medaka snapshot --bless --out test/snapshots/compiler compiler/frontend/lexer.mdk")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  (or, family-aware:  sh test/diff_compiler_snapshot_frontend.sh --bless compiler/frontend/lexer.mdk)")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig false "snapshotHelpText" (TyCon "String"))
(DFunDef false "snapshotHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka snapshot — Per-stage snapshot tests\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka snapshot [--check | --new | --bless] <paths...>\n")) (ELit (LString "                  [--out <dir>] [--stages <a,b,...>] [--isolate]\n")) (ELit (LString "\n")) (ELit (LString "One mode is REQUIRED, and the three are mutually exclusive:\n")) (ELit (LString "  --check   compare against the existing snapshot; write nothing\n")) (ELit (LString "  --new     create a MISSING snapshot; never touch an existing one\n")) (ELit (LString "  --bless   rewrite an EXISTING snapshot; never create one; requires\n")) (ELit (LString "            explicit targets (no whole-suite bless)\n")) (ELit (LString "\n")) (ELit (LString "  --out <dir>       snapshot directory (default derived from MEDAKA_ROOT)\n")) (ELit (LString "  --stages a,b,...   restrict to the named stages (default: every stage)\n")) (ELit (LString "  --isolate          run one process per fixture (debug aid for a crasher)\n")) (ELit (LString "\n")) (ELit (LString "A path may be a file or directory (recursively expanded).\n")))))
(DTypeSig false "runSnapshotCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runSnapshotCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "root") (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--root"))) (EVar "argv")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))))) (DoLet false false (PVar "sel") (EApp (EVar "snapshotStages") (EVar "argv"))) (DoLet false false (PVar "targets") (EApp (EVar "snapshotTargets") (EVar "argv"))) (DoLet false false PWild (EApp (EApp (EVar "assertBlessIsScoped") (EVar "argv")) (EVar "targets"))) (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoLet false false PWild (EApp (EVar "assertSnapshotTargetsExist") (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "files") (EListLit)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka snapshot [--check|--new|--bless] [--out <dir>] [--stages <a,b,…>] <paths...>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EIf (EApp (EApp (EVar "hasFlag") (ELit (LString "--worker"))) (EVar "argv")) (EApp (EApp (EApp (EVar "runSnapshotWorker") (EVar "root")) (EVar "sel")) (EVar "files")) (EMatch (EApp (EVar "snapshotMode") (EVar "argv")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: pass --check (verify), --new (create missing snapshots) or --bless (rewrite existing ones)")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Some" (PVar "mode")) () (EBlock (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSnapshotSupervisor") (EVar "root")) (EVar "mode")) (EApp (EApp (EVar "hasFlag") (ELit (LString "--isolate"))) (EVar "argv"))) (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--out"))) (EVar "argv"))) (EVar "sel")) (EVar "files"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))))))))
(DTypeSig false "snapshotMode" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "SnapMode")))))
(DFunDef false "snapshotMode" ((PVar "argv")) (EBlock (DoLet false false (PVar "modes") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EApp (EVar "hasFlag") (EVar "f")) (EVar "argv")))) (EListLit (ELit (LString "--check")) (ELit (LString "--new")) (ELit (LString "--bless"))))) (DoExpr (EMatch (EVar "modes") (arm (PList (PLit (LString "--check"))) () (EApp (EVar "Some") (EVar "SnapCheck"))) (arm (PList (PLit (LString "--new"))) () (EApp (EVar "Some") (EVar "SnapNew"))) (arm (PList (PLit (LString "--bless"))) () (EApp (EVar "Some") (EVar "SnapBless"))) (arm (PList) () (EVar "None")) (arm (PVar "many") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "many")))) (ELit (LString " are mutually exclusive — pick one."))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EVar "None"))))))))
(DTypeSig false "snapshotStages" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "snapshotStages" ((PVar "argv")) (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--stages"))) (EVar "argv")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "spec")) () (EMatch (EApp (EVar "parseStages") (EVar "spec")) (arm (PCon "Ok" (PVar "names")) () (EVar "names")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit))))))))
(DTypeSig false "snapshotTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "snapshotTargets" ((PList)) (EListLit))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--out")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--root")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--stages")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "snapshotTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "snapshotTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "snapFlagValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "snapFlagValue" (PWild (PList)) (EVar "None"))
(DFunDef false "snapFlagValue" (PWild (PList PWild)) (EVar "None"))
(DFunDef false "snapFlagValue" ((PVar "name") (PCons (PVar "a") (PCons (PVar "v") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "name")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "snapFlagValue") (EVar "name")) (EBinOp "::" (EVar "v") (EVar "rest")))))
(DTypeSig false "dirOf2" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf2" ((PVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo2" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo2" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo2" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "replUsageLine" (TyCon "String"))
(DFunDef false "replUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka repl — Start the interactive REPL\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka repl     Start an interactive session that reads expressions\n")) (ELit (LString "                 from stdin, evaluates them, and prints results until\n")) (ELit (LString "                 stdin closes (EOF) or you enter :quit.\n")))))
(DTypeSig false "runReplCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runReplCmd" ((PList)) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "preludeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false PWild (EApp (EApp (EVar "initSession") (EVar "runtimeDecls")) (EVar "preludeDecls"))) (DoExpr (EApp (EVar "replLoop") (ELit LUnit)))))))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka repl: unknown option '")) (EVar "bad")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "lspUsageLine" (TyCon "String"))
(DFunDef false "lspUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lsp — Run the Language Server Protocol server over stdio\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka lsp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an LSP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n")))))
(DTypeSig false "runLspCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspCmd" ((PList)) (EApp (EVar "runLspServerFromEnv") (ELit LUnit)))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lsp: unknown option '")) (EVar "bad")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "runLspServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EApp (EApp (EVar "runServer") (EVar "rsrc")) (EVar "csrc")))))))))
(DTypeSig false "mcpUsage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "mcpUsage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka mcp — Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka mcp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an MCP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n"))))))
(DTypeSig false "runMcpCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpCmd" ((PList)) (EApp (EVar "runMcpServerFromEnv") (ELit LUnit)))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "mcpUsage") (ELit LUnit))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "mcpUsage") (ELit LUnit))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka mcp: unknown argument '")) (EVar "bad")) (ELit (LString "' (mcp takes no arguments; try 'medaka mcp --help')"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "runMcpServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EApp (EApp (EApp (EApp (EVar "runMcpServer") (EVar "rsrc")) (EVar "csrc")) (EVar "stdlibDir")) (EVar "sourceStalenessVerdict")))))))))
# MARK
(DUse false (UseGroup ("tools" "check") ((mem "runCheck" false) (mem "checkHasErrors" false) (mem "runCheckModules" false))))
(DUse false (UseGroup ("tools" "snapshot") ((mem "runSnapshotWorker" false) (mem "runSnapshotSupervisor" false) (mem "parseStages" false) (mem "SnapMode" true))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "gate_cmd") ((mem "gateHelpText" false) (mem "runGateCmd" false))))
(DUse false (UseGroup ("tools" "new_cmd") ((mem "newProject" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "BuildResult" false) (mem "BuildOk" false) (mem "BuildErr" false) (mem "BuildTarget" false) (mem "TNative" false) (mem "TWasm" false) (mem "runBuild" false) (mem "emitRtObj" false) (mem "emitPreludeObj" false) (mem "envOr" false) (mem "defaultMedakaRoot" false) (mem "readPreludeFile" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinNl" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "endsWith" false) (mem "anyList" false) (mem "filterList" false) (mem "contains" false) (mem "sortUniqS" false) (mem "schemeLineName" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false) (mem "joinPath" false))))
(DUse false (UseGroup ("support" "timer") ((mem "perfEnabled" false) (mem "now" false) (mem "emitPhase" false) (mem "emitTotal" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" false) (mem "LetBind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseWithPositions" false) (mem "parseWithPositionsLocated" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "Positions" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "resolveModulesToHumaneByPath" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" false) (mem "LoadMsg" false) (mem "LoadParseFailed" false) (mem "loadProgramFilesLocatedE" false) (mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false) (mem "entrySearchRoots" false) (mem "projectTrustedMods" false) (mem "stdlibOwnership" false) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false) (mem "availableModulesText" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeProject" false) (mem "analyzeLocated" false) (mem "analyzeLocatedG" false) (mem "ppDiagCli" false) (mem "ppDiagCliSrc" false) (mem "ppDiagCliLines" false) (mem "srcLinesArr" false) (mem "Diag" true) (mem "Severity" true) (mem "SevError" false) (mem "cjPosition" false) (mem "cjRange" false) (mem "cjRangeOfLoc" false) (mem "cjDiagnostic" false) (mem "cjFileEntry" false) (mem "cjAllToJson" false) (mem "readDiagSrc" false) (mem "parseErrCode" false) (mem "parseErrHelpFix" false) (mem "codeKind" false) (mem "optField" false) (mem "cjFixJson" false) (mem "mkDiag" false) (mem "checkJsonFile" false) (mem "readFileSafe" false) (mem "diagIsError" false) (mem "findMainFunDef" false) (mem "mainBodyLoc" false) (mem "mainArityMsg" false) (mem "mainNonUnitMsg" false) (mem "mainArityWarning" false) (mem "mainNonUnitWarning" false) (mem "mainShapeWarnings" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "JNull" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateModules" false) (mem "resetTypeErrorsSticky" false) (mem "hadTypeErrors" false) (mem "mainTypeIsAsync" false) (mem "mainTypeIsUnit" false) (mem "setStdlibOwnership" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "evalModulesOutputRun" false) (mem "evalModulesOutputAsync" false) (mem "currentEvalFile" false) (mem "modulePathMap" false) (mem "runJsonMode" false) (mem "pendingRunDiags" false) (mem "progArgsRef" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTest" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Engine" true))))
(DUse false (UseGroup ("tools" "repl") ((mem "initSession" false) (mem "replLoop" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "runServer" false))))
(DUse false (UseGroup ("tools" "mcp") ((mem "runMcpServer" false))))
(DUse false (UseGroup ("tools" "doc") ((mem "runDoc" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "allRules" false) (mem "lintProgram" false) (mem "applySuppressions" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMultiDirs" false) (mem "collectDirectives" false) (mem "findingToDiag" false) (mem "Finding" false) (mem "Directive" false) (mem "applyFixes" false) (mem "runCrossFileRules" false) (mem "runCrossFileRulesFromOccs" false) (mem "crossFileCacheSound" false) (mem "fileDupOccs" false) (mem "parseLintFlagList" false) (mem "applyFindingFilters" false) (mem "applyFindingDeny" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "splitLintNames" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "LintEntry" true) (mem "contentHashOf" false) (mem "ruleSetStamp" false) (mem "cacheDirOf" false) (mem "loadEntry" false) (mem "storeEntries" false))))
(DUse false (UseGroup ("tools" "codemod") ((mem "findCodemod" false) (mem "codemodMk" false) (mem "codemodWarnDecls" false) (mem "codemodListing" false) (mem "codemodSource" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "runCheckPolicy" false) (mem "PolicyArgs" true) (mem "parsePolicyArgs" false) (mem "PolicyOutcome" true) (mem "runManifest" false) (mem "parseManifestArgs" false) (mem "ManifestArgs" true))))
(DTypeSig false "medakaVersion" (TyCon "String"))
(DFunDef false "medakaVersion" () (ELit (LString "0.1.0-preview")))
(DTypeSig false "printVersion" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printVersion" (PWild) (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "medaka ")) (EVar "medakaVersion"))))
(DTypeSig false "liveSourceFingerprint" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "liveSourceFingerprint" ((PVar "root")) (EBlock (DoLet false false (PVar "script") (EApp (EVar "stringConcat") (EListLit (ELit (LString "command -v perl >/dev/null 2>&1 || exit 7; cd \"")) (EVar "root") (ELit (LString "\" && find compiler -name '*.mdk' -print | LC_ALL=C sort")) (ELit (LString " | perl -ne 'chomp; print \"$_\\n\"; open F,\"<\",$_ or next; local $/; my $c=<F>; print $c if defined $c; close F' 2>/dev/null")) (ELit (LString " | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif command -v shasum >/dev/null 2>&1; then shasum -a 256; else cksum; fi; }")) (ELit (LString " | cut -d' ' -f1"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EVar "script"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "h") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "h") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "h")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "sourceStalenessVerdict" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sourceStalenessVerdict" (PWild) (EBlock (DoLet false false (PVar "baked") (EApp (EVar "buildFingerprint") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "baked") (ELit (LString ""))) (EVar "None") (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "compilerDir"))) (EVar "None") (EMatch (EApp (EVar "liveSourceFingerprint") (EVar "root")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "live")) () (EIf (EBinOp "==" (EVar "live") (EVar "baked")) (EVar "None") (EApp (EVar "Some") (EVar "compilerDir"))))))))))))
(DTypeSig false "checkSourceStaleness" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "checkSourceStaleness" (PWild) (EMatch (EApp (EVar "sourceStalenessVerdict") (ELit LUnit)) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "compilerDir")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EBinOp "++" (ELit (LString "warning: this ./medaka was built from compiler source that differs from ")) (EVar "compilerDir")) (ELit (LString " — it may be stale; rebuild with 'make medaka'.")))) (DoExpr (EIf (EBinOp "/=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_STRICT"))) (ELit (LString ""))) (ELit (LString ""))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EApp (EVar "ePutStrLn") (EVar "msg"))))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false PWild (EApp (EVar "checkSourceStaleness") (ELit LUnit))) (DoExpr (EApp (EVar "runCli") (ELit LUnit)))))
(DTypeSig false "runCli" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCli" (PWild) (EMatch (EApp (EVar "args") (ELit LUnit)) (arm (PList) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "-h")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "-v")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "check")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "checkHelpText")) (EVar "runCheckCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "fmt")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "fmtHelpText")) (EVar "runFmtCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "new")) (PVar "rest")) () (EApp (EVar "runNewCmd") (EVar "rest"))) (arm (PCons (PLit (LString "build")) (PVar "rest")) () (EApp (EVar "runBuildCmd") (EVar "rest"))) (arm (PCons (PLit (LString "run")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "runHelpText")) (EVar "runRunCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "test")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "testHelpText")) (EVar "runTestCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "snapshot")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "snapshotHelpText")) (EVar "runSnapshotCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "doc")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "docHelpText")) (EVar "runDocCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "lint")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "lintHelpText")) (EVar "runLintCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "codemod")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "codemodHelpText")) (EVar "runCodemodCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "check-policy")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "checkPolicyHelpText")) (EVar "runCheckPolicyCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "manifest")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "manifestHelpText")) (EVar "runManifestCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "gate")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "gateHelpText")) (EVar "runGateCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "repl")) (PVar "rest")) () (EApp (EVar "runReplCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lsp")) (PVar "rest")) () (EApp (EVar "runLspCmd") (EVar "rest"))) (arm (PCons (PLit (LString "mcp")) (PVar "rest")) () (EApp (EVar "runMcpCmd") (EVar "rest"))) (arm (PCons (PVar "sub") PWild) () (EApp (EVar "notYet") (EMethodRef "sub")))))
(DTypeSig false "dispatchSub" (TyFun (TyCon "String") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "dispatchSub" ((PVar "help") PWild (PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "help"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "dispatchSub" ((PVar "help") PWild (PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "help"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "dispatchSub" (PWild (PVar "run") (PVar "rest")) (EApp (EVar "run") (EVar "rest")))
(DTypeSig false "usage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "usage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka. A functional language compiler\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka                    Show this message\n")) (ELit (LString "  medaka run [--release] <file.mdk>   Type-check and run a program\n")) (ELit (LString "  medaka build <file.mdk> [-o <out>] [--keep-ir]  Compile to a native binary (LLVM + clang)\n")) (ELit (LString "  medaka check [--json] <file.mdk>    Type-check without running\n")) (ELit (LString "  medaka test [--native | --engines eval,native] [file.mdk]    Run doctests + prop tests (--native runs doctests through a compiled native binary INSTEAD of the interpreter; --engines runs the listed set, exit is the AND)\n")) (ELit (LString "  medaka doc [file.mdk]     Generate Markdown documentation\n")) (ELit (LString "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --cache, --disable/--only/--deny=<rules,...>)\n")) (ELit (LString "  medaka codemod <name> [flags] [paths...]  Apply a named source-preserving AST transform (--write/--stdout)\n")) (ELit (LString "  medaka snapshot [--check|--new|--bless] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n")) (ELit (LString "  medaka fmt [paths...]     Report unformatted files (default; use --write to rewrite in place)\n")) (ELit (LString "  medaka new <name>         Scaffold a new project directory\n")) (ELit (LString "  medaka repl               Start an interactive REPL (reads stdin until EOF or :quit)\n")) (ELit (LString "  medaka lsp                Run the language server over stdio\n")) (ELit (LString "  medaka mcp                Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]  Check a plugin's inferred effects against an allow-list\n")) (ELit (LString "  medaka manifest <file.mdk> [--fn name]  Emit the verified capability manifest as TOML\n")) (ELit (LString "  medaka gate list [<selector>...] [--json]  Query the gate registry (test/gates.toml)\n")) (ELit (LString "  medaka gate run [<selector>...] [--dry-run]  Run the selected gates\n")) (ELit (LString "  medaka help               Show this message\n")) (ELit (LString "  medaka --version          Show the compiler version\n"))))))
(DTypeSig false "notYet" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "notYet" ((PVar "sub")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka: subcommand '")) (EMethodRef "sub")) (ELit (LString "' not yet in native CLI"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "ppParseError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "ppParseError" ((PVar "src") (PVar "file") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EApp (EVar "parseErrorCol") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "h") (PVar "fx")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "h")) (EVar "fx"))))))
(DTypeSig false "checkHelpText" (TyCon "String"))
(DFunDef false "checkHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka check — Type-check a file without running it\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka check [--json] [--types] [--allow-internal] <file.mdk>\n")) (ELit (LString "\n")) (ELit (LString "  --json            emit the {\"files\":[...]} structured-diagnostics\n")) (ELit (LString "                    envelope instead of human text\n")) (ELit (LString "  --types           show the full inferred-scheme dump, prelude included\n")) (ELit (LString "                    (default: only your own top-level bindings)\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")))))
(DTypeSig false "runCheckCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "typesMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--types"))) (EVar "argv"))) (DoLet false false (PVar "argv2") (EApp (EVar "dropFlags") (EVar "argv"))) (DoExpr (EMatch (EVar "argv2") (arm (PList (PVar "target")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EApp (EVar "runCheckJsonCmd") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EMethodRef "map") (EVar "dropModPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false PWild (EApp (EApp (EVar "setStdlibOwnership") (EVar "flatStdlib")) (EVar "ownedStdlib"))) (DoLet false false (PVar "perfTLoad") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "load"))) (EBinOp "-" (EVar "perfTLoad") (EVar "perfT0"))) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRoute") (EVar "typesMode")) (EVar "allowInternal")) (EVar "trusted")) (EVar "pathMap")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "mods"))) (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoExpr (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTCheck") (EVar "perfT0"))))))))))))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check [--json] [--types] [--allow-internal] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DTypeSig false "moduleLoadErrText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "e"))) (EApp (EApp (EApp (EVar "ppParseError") (EVar "msrc")) (EVar "mpath")) (EVar "e")))
(DFunDef false "moduleLoadErrText" ((PVar "tsrc") (PVar "target") (PVar "stdlibDir") (PCon "LoadMsg" (PVar "lmsg"))) (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EVar "lmsg") (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "tsrc"))) (arm (PCon "None") () (EVar "msg")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "msg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))))))
(DTypeSig false "locatedProjectErrors" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "locatedProjectErrors" ((PVar "allowInternal") (PVar "trusted") (PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EApp (EVar "errTextOf") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedProjectDiags") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))))
(DTypeSig false "errTextOf" (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "errTextOf" ((PTuple (PVar "errText") PWild PWild)) (EVar "errText"))
(DTypeSig false "locatedProjectDiags" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Int"))))))))))
(DFunDef false "locatedProjectDiags" ((PVar "allowInternal") (PVar "trusted") (PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "allowInternal")) (EVar "trusted")) (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EVar "results"))) (DoExpr (ETuple (EApp (EVar "joinedOrNone") (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleErrors")) (EVar "triples"))) (EApp (EApp (EMethodRef "map") (EVar "cohWarnsOfTriple")) (EVar "triples")) (EApp (EMethodRef "length") (EApp (EApp (EDictApp "flatMap") (EVar "hiddenWarnsOfTriple")) (EApp (EVar "dropEntryTriple") (EVar "triples"))))))))
(DTypeSig false "cohWarnsOfTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "cohWarnsOfTriple" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (ETuple (EVar "path") (EVar "src") (EApp (EApp (EMethodRef "filter") (EVar "isCoherenceWarn")) (EVar "diags"))))
(DTypeSig false "hiddenWarnsOfTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "Diag"))))
(DFunDef false "hiddenWarnsOfTriple" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EMethodRef "filter") (EVar "isHiddenNonEntryWarn")) (EVar "diags")))
(DTypeSig false "isHiddenNonEntryWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isHiddenNonEntryWarn" ((PVar "d")) (EBinOp "&&" (EApp (EVar "isDiagWarn") (EVar "d")) (EApp (EVar "not") (EApp (EVar "isCoherenceWarn") (EVar "d")))))
(DTypeSig false "joinedOrNone" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "joinedOrNone" ((PList)) (EVar "None"))
(DFunDef false "joinedOrNone" ((PVar "ls")) (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "ls"))))
(DTypeSig false "renderTripleErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EVar "errs")))))))
(DTypeSig false "renderTripleWarnings" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleWarnings" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EBlock (DoLet false false (PVar "ws") (EApp (EApp (EMethodRef "filter") (EVar "isDiagWarn")) (EVar "diags"))) (DoExpr (EMatch (EVar "ws") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EVar "ws")))))))
(DTypeSig false "locatedOrGeneric" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))))))
(DFunDef false "locatedOrGeneric" ((PVar "allowInternal") (PVar "trusted") (PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: type error in ")) (EVar "target")) (ELit (LString ", detected during elaboration (the run/build type pass); no located"))) (ELit (LString " diagnostic is available for it, and `medaka check` may not report this"))) (ELit (LString " program at all — see issue #1812"))))))
(DTypeSig false "checkRoute" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Unit")))))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") PWild PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") (PVar "decls")))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "mid")) (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false (PVar "warns") (EApp (EApp (EMethodRef "filter") (EVar "isDiagWarn")) (EVar "diags"))) (DoLet false false (PVar "dump") (EApp (EVar "stripWarningLines") (EApp (EApp (EApp (EVar "runCheck") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoLet false false (PVar "filtered") (EApp (EApp (EVar "userSchemeLines") (EVar "decls")) (EVar "dump"))) (DoLet false false (PVar "report") (EIf (EVar "typesMode") (EVar "dump") (EVar "filtered"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "report"))) (DoLet false false PWild (EIf (EVar "typesMode") (ELit LUnit) (EApp (EVar "putStrLn") (EApp (EApp (EVar "checkOkLine") (EVar "target")) (EVar "filtered"))))) (DoLet false false (PVar "mainWarns") (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "decls"))))) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EBinOp "++" (EVar "warns") (EVar "mainWarns")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") (PVar "pathMap") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneByPath") (EVar "pathMap")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedProjectDiags") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "errText"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PTuple (PCon "None") (PVar "projWarns") (PVar "hiddenCount")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EApp (EApp (EApp (EApp (EVar "runCheckModules") (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD")))) (DoLet false false PWild (EApp (EVar "emitWarningLines") (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleWarnings")) (EApp (EVar "trimEntryTriple") (EVar "projWarns"))))) (DoLet false false PWild (EApp (EVar "emitHiddenDiagNote") (EVar "hiddenCount"))) (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple (PVar "emid") (PVar "edecls"))) () (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EVar "rtD")) (EVar "coreD")) (EVar "modsD")) (EVar "edecls"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EVar "mainWarns"))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DTypeSig false "lastModPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lastModPair" ((PList)) (EVar "None"))
(DFunDef false "lastModPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "lastModPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModPair") (EVar "rest")))
(DTypeSig false "dropFlags" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropFlags" ((PList)) (EListLit))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--json")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--release")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--allow-internal")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--types")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropFlags") (EVar "rest"))))
(DTypeSig false "hasFlag" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "hasFlag" (PWild (PList)) (EVar "False"))
(DFunDef false "hasFlag" ((PVar "flag") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "flag")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "hasFlag") (EVar "flag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runCheckJsonCmd" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runCheckJsonCmd" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjFileNotFoundJson") (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir"))) (DoLet false false PWild (EApp (EDictApp "println") (EVar "json"))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))
(DTypeSig false "cjBuildFailedJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "cjBuildFailedJson" ((PVar "target") (PVar "msg")) (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (ELit (LString "")) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-BUILD-FAILED"))) (EVar "msg")) (EVar "None")) (EVar "None")) (EVar "None")))))))
(DTypeSig false "runBuildJsonCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "runBuildJsonCmd" ((PVar "argv") (PVar "allowInternal") (PVar "root") (PVar "stdlibDir") (PVar "input") (PVar "outOpt") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "input")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjFileNotFoundJson") (EVar "input")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (EVar "msg")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (EVar "msg")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "input")) (EVar "stdlibDir"))) (DoExpr (EIf (EVar "hasErr") (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EVar "json"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "keepIrCli") (EApp (EApp (EVar "hasFlag") (ELit (LString "--keep-ir"))) (EVar "argv"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "input")) (EVar "outPath")) (EVar "keepIrCli")) (arm (PCon "BuildOk" PWild) () (EApp (EDictApp "println") (EVar "json"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (EVar "msg")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))))))))))))))
(DTypeSig false "cjFileNotFoundJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "cjFileNotFoundJson" ((PVar "target") (PVar "err")) (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read file '")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "': "))) (EApp (EMethodRef "display") (EVar "err"))) (ELit (LString "")))) (DoLet false false (PVar "diagJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (ELit (LString "R-FILE-NOT-FOUND")))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "resolve")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "range")) (EVar "JNull")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka"))))))) (DoLet false false (PVar "filesJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "target"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EListLit (EVar "diagJson"))))))) (DoExpr (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "jArray") (EListLit (EVar "filesJson"))))))))))
(DTypeSig false "isDiagError" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isDiagError" ((PCon "Diag" (PCon "SevError") PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isDiagError" (PWild) (EVar "False"))
(DTypeSig false "isDiagWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isDiagWarn" ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isDiagError") (EVar "d"))))
(DTypeSig false "coherenceWarnCode" (TyCon "String"))
(DFunDef false "coherenceWarnCode" () (ELit (LString "W-INCOMPARABLE-IMPLS")))
(DTypeSig false "runBuildWarnCodes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "runBuildWarnCodes" () (EListLit (EVar "coherenceWarnCode") (ELit (LString "W-PRELUDE-METHOD-SHADOW"))))
(DTypeSig false "isCoherenceWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isCoherenceWarn" ((PCon "Diag" (PCon "SevWarning") (PVar "c") PWild PWild PWild PWild)) (EApp (EApp (EVar "contains") (EVar "c")) (EVar "runBuildWarnCodes")))
(DFunDef false "isCoherenceWarn" (PWild) (EVar "False"))
(DTypeSig false "stripWarningLines" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripWarningLines" ((PVar "s")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "Warning: "))) (EVar "l"))))) (EApp (EVar "splitNl") (EVar "s")))))
(DTypeSig false "userSchemeLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "userSchemeLines" ((PVar "decls") (PVar "report")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "omFromNames") (EApp (EVar "topLevelNames") (EVar "decls"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "filter") (EApp (EVar "namesUserBinding") (EVar "names"))) (EApp (EVar "splitNl") (EVar "report")))))))
(DTypeSig false "checkOkLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "checkOkLine" ((PVar "target") (PVar "filtered")) (EBlock (DoLet false false (PVar "n") (EApp (EMethodRef "length") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitNl") (EVar "filtered"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "-- ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": ok ("))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " declaration(s) checked, 0 errors)"))))))
(DTypeSig false "namesUserBinding" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "namesUserBinding" ((PVar "names") (PVar "l")) (EMatch (EApp (EVar "schemeLineName") (EVar "l")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "topLevelNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topLevelNames" ((PList)) (EListLit))
(DFunDef false "topLevelNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "topLevelNames") (EListLit (EVar "d"))) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "topLevelNames") (EVar "rest")))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "emitLocatedWarnings" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitLocatedWarnings" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "emitLocatedWarnings" ((PVar "src") (PVar "file") (PVar "ws")) (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "file"))) (EVar "ws")))))
(DTypeSig false "emitWarningLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emitWarningLines" ((PList)) (ELit LUnit))
(DFunDef false "emitWarningLines" ((PVar "ls")) (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EVar "ls"))))
(DTypeSig false "emitHiddenDiagNote" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emitHiddenDiagNote" ((PLit (LInt 0))) (ELit LUnit))
(DFunDef false "emitHiddenDiagNote" ((PVar "n")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " further diagnostic(s) in imported modules; rerun with --json to see them")))))
(DTypeSig false "cohWarnTriples" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "cohWarnTriples" ((PVar "src") (PVar "file") (PVar "diags")) (EMatch (EApp (EApp (EMethodRef "filter") (EVar "isCoherenceWarn")) (EVar "diags")) (arm (PList) () (EListLit)) (arm (PVar "ws") () (EListLit (ETuple (EVar "file") (EVar "src") (EVar "ws"))))))
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
(DFunDef false "onTypecheckWarnChannel" ((PCon "Diag" PWild (PVar "c") PWild PWild PWild PWild)) (EBinOp "==" (EVar "c") (EVar "coherenceWarnCode")))
(DTypeSig false "tripleHasDiags" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "tripleHasDiags" ((PTuple PWild PWild (PList))) (EVar "False"))
(DFunDef false "tripleHasDiags" (PWild) (EVar "True"))
(DData Private "FmtMode" () ((variant "FmtWrite" (ConPos)) (variant "FmtStdout" (ConPos)) (variant "FmtCheck" (ConPos))) ())
(DTypeSig false "fmtHelpText" (TyCon "String"))
(DFunDef false "fmtHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka fmt — Format .mdk file(s)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka fmt [--check | --stdout | --write] <path>...\n")) (ELit (LString "\n")) (ELit (LString "Read-only unless --write is given.\n")) (ELit (LString "\n")) (ELit (LString "  (default)    same as --check: reports files that are not formatted\n")) (ELit (LString "               (exit 1 if any); prints nothing when already formatted.\n")) (ELit (LString "               Never writes.\n")) (ELit (LString "  --check      explicit form of the default\n")) (ELit (LString "  --stdout     print the formatted result to stdout (single file only);\n")) (ELit (LString "               never writes\n")) (ELit (LString "  --write, -w  rewrite the file(s) in place and print a one-line summary\n")) (ELit (LString "               (\"formatted N file(s)\" / \"already formatted\")\n")) (ELit (LString "\n")) (ELit (LString "A path may be a file or a directory (recursively expanded; dotfiles and\n")) (ELit (LString "dot-dirs are skipped).\n")))))
(DTypeSig false "runFmtCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runFmtCmd" ((PVar "argv")) (EMatch (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "argv")) (EVar "FmtCheck")) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple PWild (PList))) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka fmt [--check | --stdout | --write] <path>...")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PList (PVar "target")))) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "fmtOne") (EVar "mode")) (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EListLit (EVar "target")))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "targets"))) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EVar "targets")))))
(DTypeSig false "fmtManyTargets" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtManyTargets" ((PCon "FmtStdout") PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DFunDef false "fmtManyTargets" ((PVar "mode") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: no .mdk files found")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm PWild () (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "changed")) (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "files")) (ETuple (EVar "False") (ELit (LInt 0))))) (DoLet false false PWild (EMatch (EVar "mode") (arm (PCon "FmtWrite") () (EApp (EVar "putStrLn") (EApp (EVar "fmtWriteSummaryLine") (EVar "changed")))) (arm PWild () (ELit LUnit)))) (DoExpr (EIf (EVar "hadErr") (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "fmtFilesGo" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Bool") (TyCon "Int")) (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyCon "Int")))))))
(DFunDef false "fmtFilesGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fmtFilesGo" ((PVar "mode") (PCons (PVar "f") (PVar "rest")) (PTuple (PVar "errAcc") (PVar "changedAcc"))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "changed")) (EApp (EApp (EVar "fmtOneReport") (EVar "mode")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "rest")) (ETuple (EBinOp "||" (EVar "errAcc") (EVar "hadErr")) (EBinOp "+" (EVar "changedAcc") (EIf (EVar "changed") (ELit (LInt 1)) (ELit (LInt 0)))))))))
(DTypeSig false "fmtWriteSummaryLine" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "fmtWriteSummaryLine" ((PLit (LInt 0))) (ELit (LString "already formatted")))
(DFunDef false "fmtWriteSummaryLine" ((PLit (LInt 1))) (ELit (LString "formatted 1 file")))
(DFunDef false "fmtWriteSummaryLine" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "formatted ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " files"))))
(DTypeSig false "fmtOneReport" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "fmtOneReport" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "formatted"))) (DoExpr (ETuple (EVar "False") (EVar "False"))))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ETuple (EVar "False") (EVar "False")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (ETuple (EVar "True") (EVar "False")))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ETuple (EVar "False") (EVar "False")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" PWild) () (ETuple (EVar "False") (EVar "True"))))))))))))))
(DTypeSig false "parseFmtArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "FmtMode") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "parseFmtArgs" ((PList) (PVar "mode") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "acc")))))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--check")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtCheck")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtStdout")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "-w")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PVar "x") (PVar "rest")) (PVar "mode") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "x")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (ELit (LString "medaka fmt: unknown flag: ")) (EVar "x"))) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "mode")) (EBinOp "::" (EVar "x") (EVar "acc")))))
(DTypeSig false "fmtOne" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtOne" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EApp (EVar "putStr") (EVar "formatted"))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EApp (EVar "putStrLn") (ELit (LString "already formatted"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStrLn") (ELit (LString "formatted 1 file")))))))))))))))
(DData Private "CodeMode" () ((variant "CmDry" (ConPos)) (variant "CmWrite" (ConPos)) (variant "CmStdout" (ConPos))) ())
(DTypeSig false "codemodHelpText" (TyCon "String"))
(DFunDef false "codemodHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka codemod — Apply a named source-preserving AST transform\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka codemod <name> [flags] [--write|--stdout] <paths...>\n")) (ELit (LString "\n")) (ELit (LString "  (default)  dry-run: prints \"would rewrite: <file>\" per changed file,\n")) (ELit (LString "             exits 1 if any file would change. Never writes.\n")) (ELit (LString "  --write    rewrite only the files that actually change\n")) (ELit (LString "  --stdout   print one file's result (single file only)\n")) (ELit (LString "\n")) (ELit (LString "Any other --flag consumes the next token as its value, passed to the\n")) (ELit (LString "named codemod. Run `medaka codemod` with no arguments to list the\n")) (ELit (LString "available codemods.\n")) (ELit (LString "\n")) (ELit (LString "NOTE: `--help`/`-h` is only recognized in the FIRST position — as\n")) (ELit (LString "`medaka codemod --help`, before a codemod name. `medaka codemod <name>\n")) (ELit (LString "--help` is NOT special-cased (it is a codemod flag) and codemod-specific\n")) (ELit (LString "help does not exist yet.\n")))))
(DTypeSig false "runCodemodCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCodemodCmd" ((PList)) (EApp (EVar "listCodemodsAndExit") (ELit LUnit)))
(DFunDef false "runCodemodCmd" ((PCons (PVar "name") (PVar "rest"))) (EMatch (EApp (EVar "findCodemod") (EVar "name")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: unknown codemod '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "'"))))) (DoExpr (EApp (EVar "listCodemodsAndExit") (ELit LUnit))))) (arm (PCon "Some" (PVar "cm")) () (EMatch (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmDry")) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "cargs") (PVar "targets"))) () (EMatch (EApp (EApp (EVar "codemodMk") (EVar "cm")) (EVar "cargs")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "xf")) () (EBlock (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka codemod: no .mdk files found")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm PWild () (EMatch (EVar "mode") (arm (PCon "CmStdout") () (EMatch (EVar "files") (arm (PList (PVar "one")) () (EApp (EApp (EApp (EVar "codemodStdout") (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "one"))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka codemod: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))))) (arm PWild () (EIf (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))))))))
(DTypeSig false "listCodemodsAndExit" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "listCodemodsAndExit" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "Usage: medaka codemod <name> [flags] [--write|--stdout] <paths...>")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "Available codemods:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "codemodListing"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DTypeSig false "splitCodemodArgv" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CodeMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "CodeMode") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "splitCodemodArgv" ((PList) (PVar "mode") (PVar "cargs") (PVar "paths")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "cargs")) (EApp (EVar "reverseL") (EVar "paths")))))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmWrite")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmStdout")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PVar "tok") (PVar "rest")) (PVar "mode") (PVar "cargs") (PVar "paths")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "tok")) (EMatch (EVar "rest") (arm (PCons (PVar "v") (PVar "rest2")) () (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest2")) (EVar "mode")) (EBinOp "::" (EVar "v") (EBinOp "::" (EVar "tok") (EVar "cargs")))) (EVar "paths"))) (arm (PList) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: flag '")) (EApp (EMethodRef "display") (EVar "tok"))) (ELit (LString "' requires a value")))))) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "mode")) (EVar "cargs")) (EBinOp "::" (EVar "tok") (EVar "paths")))))
(DTypeSig false "codemodStdout" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "codemodStdout" ((PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EApp (EVar "putStr") (EVar "src"))) (arm (PCon "Some" (PVar "out")) () (EApp (EVar "putStr") (EVar "out")))))))))))
(DTypeSig false "codemodFilesGo" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "codemodFilesGo" (PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "codemodFilesGo" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "signal") (EApp (EApp (EApp (EApp (EVar "codemodOneReport") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "signal"))))))
(DTypeSig false "codemodOneReport" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "codemodOneReport" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "out")) () (EMatch (EVar "mode") (arm (PCon "CmWrite") () (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "out")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EVar "False")))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "would rewrite: ")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ""))))) (DoExpr (EVar "True"))))))))))))))
(DTypeSig false "emitCodemodWarns" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitCodemodWarns" ((PVar "warnFn") (PVar "file") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "decls") PWild) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EApp (EVar "warnFn") (EVar "decls"))))))
(DTypeSig false "emitWarnLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitWarnLines" (PWild (PList)) (ELit LUnit))
(DFunDef false "emitWarnLines" ((PVar "file") (PCons (PVar "w") (PVar "ws"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": warning: "))) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EVar "ws")))))
(DTypeSig false "newUsageLine" (TyCon "String"))
(DFunDef false "newUsageLine" () (ELit (LString "Usage: medaka new <name>")))
(DTypeSig false "runNewCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runNewCmd" ((PList (PVar "arg"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "arg") (ELit (LString "--help"))) (EBinOp "==" (EVar "arg") (ELit (LString "-h")))) (EApp (EVar "putStrLn") (EVar "newUsageLine")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "arg")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "arg")) (ELit (LString "-")))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka new: unknown option '")) (EVar "arg")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "newUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))) (EBlock (DoLet false false (PVar "code") (EApp (EVar "newProject") (EVar "arg"))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (ELit LUnit) (EApp (EVar "exit") (EVar "code"))))))))
(DFunDef false "runNewCmd" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "newUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DTypeSig false "runBuildCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildCmd" ((PVar "argv")) (EIf (EBinOp "||" (EApp (EApp (EVar "hasFlag") (ELit (LString "--help"))) (EVar "argv")) (EApp (EApp (EVar "hasFlag") (ELit (LString "-h"))) (EVar "argv"))) (EApp (EVar "buildUsage") (ELit LUnit)) (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--emit-rt-obj"))) (EVar "argv")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "emitRtObj") (EVar "cc")) (EVar "root")) (EVar "objPath")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EDictApp "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--emit-prelude-obj"))) (EVar "argv")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "./medaka")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "emitPreludeObj") (EVar "cc")) (EVar "root")) (EVar "medaka")) (EVar "objPath")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EDictApp "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv")) (EApp (EVar "runBuildJsonEntry") (EVar "argv")) (EApp (EVar "runBuildPlainCmd") (EVar "argv")))))))))
(DTypeSig false "runBuildPlainCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildPlainCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoExpr (EMatch (EApp (EVar "parseBuildArgs") (EVar "argv")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") (PVar "target"))) () (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "input"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "error: no such file: ")) (EVar "input")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "inputAbs") (EVar "input")) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "keepIrCli") (EApp (EApp (EVar "hasFlag") (ELit (LString "--keep-ir"))) (EVar "argv"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "typecheckGate") (EVar "allowInternal")) (EVar "root")) (EVar "inputAbs")) (arm (PCon "TGErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "TGOk" (PVar "gateWarns")) () (EBlock (DoLet false false PWild (EApp (EVar "emitWarningLines") (EVar "gateWarns"))) (DoLet false false (PVar "perfTTc") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "typecheck"))) (EBinOp "-" (EVar "perfTTc") (EVar "perfT0"))) (EVar "input"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")) (arm (PCon "BuildOk" (PVar "msg")) () (EBlock (DoLet false false (PVar "perfTEmit") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "emit"))) (EBinOp "-" (EVar "perfTEmit") (EVar "perfTTc"))) (EVar "input"))) (DoLet false false PWild (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTEmit") (EVar "perfT0")))) (DoExpr (EApp (EDictApp "println") (EVar "msg"))))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))))))))))))
(DTypeSig false "runBuildJsonEntry" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildJsonEntry" ((PVar "argv")) (EMatch (EApp (EVar "parseBuildArgs") (EVar "argv")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjBuildFailedJson") (ELit (LString ""))) (EVar "msg")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") (PVar "target"))) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildJsonCmd") (EVar "argv")) (EVar "allowInternal")) (EVar "root")) (EVar "stdlibDir")) (EVar "input")) (EVar "outOpt")) (EVar "target")))))))
(DTypeSig false "buildUsage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "buildUsage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>] [--keep-ir] [--allow-internal] [--json]\n")) (ELit (LString "\n")) (ELit (LString "  -o <out>          output path for the binary (default: <file> with its extension dropped)\n")) (ELit (LString "  --target <t>      backend: native (LLVM + clang, default) or wasm (WasmGC + wasm-tools)\n")) (ELit (LString "  --json            emit the {\"files\":[...]} structured-diagnostics envelope (same\n")) (ELit (LString "                    schema as `medaka check --json`) instead of human text; a genuine\n")) (ELit (LString "                    build-stage (emitter/clang) failure carries code R-BUILD-FAILED\n")) (ELit (LString "  --keep-ir         keep the emitted IR (.ll for native, .wat for wasm) at <out>.ll/.wat\n")) (ELit (LString "                    instead of discarding it with the build's scratch directory; the\n")) (ELit (LString "                    kept path is printed. Env var MEDAKA_KEEP_IR=1 does the same for a\n")) (ELit (LString "                    build invoked by something else (e.g. a test harness)\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --emit-rt-obj <p> compile only runtime/medaka_rt.c to a reusable object at <p> (with\n")) (ELit (LString "                    the same flags a normal link uses) and exit; point MEDAKA_RT_OBJ at\n")) (ELit (LString "                    it to skip recompiling the runtime on every subsequent build\n")) (ELit (LString "  --emit-prelude-obj <p>\n")) (ELit (LString "                    compile only stdlib/core.mdk to a reusable object at <p> (with the\n")) (ELit (LString "                    same flags a normal link uses) and exit; point MEDAKA_PRELUDE_OBJ at\n")) (ELit (LString "                    it to skip re-optimising the prelude on every subsequent build.\n")) (ELit (LString "                    Opt-in: separate objects cannot inline the prelude into user code\n")) (ELit (LString "\n")) (ELit (LString "runtime object cache (ON by default):\n")) (ELit (LString "  Every native build links a compiled runtime/medaka_rt.c. Rather than recompile\n")) (ELit (LString "  it each time (~0.76s), build caches the object, keyed on a hash of the .c\n")) (ELit (LString "  source, the C compiler and its version, and the exact compile flags, so a\n")) (ELit (LString "  changed runtime or compiler never reuses a stale object.\n")) (ELit (LString "  Location (first that applies): $MEDAKA_CACHE_DIR, else\n")) (ELit (LString "  $XDG_CACHE_HOME/medaka, else $HOME/.cache/medaka.\n")) (ELit (LString "  MEDAKA_NO_OBJ_CACHE=1  disable the cache; compile medaka_rt.c inline every build\n")) (ELit (LString "  MEDAKA_CACHE_DIR=<d>   put the cache somewhere else (e.g. a per-CI-job scratch dir)\n")) (ELit (LString "  An explicit MEDAKA_RT_OBJ still wins over the cache. Every cache failure is\n")) (ELit (LString "  fail-open: build falls back to the inline compile, never to an error.\n"))))))
(DTypeSig false "defaultOutPath" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "defaultOutPath" ((PCon "TNative") (PVar "input")) (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))))
(DFunDef false "defaultOutPath" ((PCon "TWasm") (PVar "input")) (EBinOp "++" (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))) (ELit (LString ".wasm"))))
(DData Private "TypecheckGate" () ((variant "TGOk" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "TGErr" (ConPos (TyCon "String")))) ())
(DTypeSig false "typecheckGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "TypecheckGate"))))))
(DFunDef false "typecheckGate" ((PVar "allowInternal") (PVar "root") (PVar "input")) (EBlock (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "input"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "input")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "TGErr") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "input")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "input")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EApp (EVar "TGErr") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "input")) (EVar "stdlibDir")) (EVar "lerr")))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EMethodRef "map") (EVar "dropModPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "input")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "input")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false PWild (EApp (EApp (EVar "setStdlibOwnership") (EVar "flatStdlib")) (EVar "ownedStdlib"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckGateRoute") (EVar "allowInternal")) (EVar "trusted")) (EVar "pathMap")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "input")) (EVar "mods")))))))))))))))))
(DTypeSig false "typecheckGateRoute" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "TypecheckGate"))))))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") PWild PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") (PVar "decls")))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "mid")) (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false (PVar "mainWarns") (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "decls"))))) (EVar "decls"))) (DoLet false false (PVar "allWarns") (EBinOp "++" (EApp (EApp (EApp (EVar "cohWarnTriples") (EVar "tsrc")) (EVar "target")) (EVar "diags")) (EApp (EVar "nonEmptyTriples") (EListLit (ETuple (EVar "target") (EVar "tsrc") (EVar "mainWarns")))))) (DoExpr (EApp (EVar "TGOk") (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleWarnings")) (EVar "allWarns")))))) (arm PWild () (EApp (EVar "TGErr") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs")))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") (PVar "pathMap") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneByPath") (EVar "pathMap")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedProjectDiags") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EApp (EVar "TGErr") (EVar "errText"))) (arm (PTuple (PCon "None") (PVar "projWarns") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EApp (EVar "TGErr") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (arm (PCon "False") () (EBlock (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EMatch (EApp (EVar "mainArityWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EMatch (EApp (EVar "mainNonUnitWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit)))))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "allWarns") (EBinOp "++" (EVar "projWarns") (EApp (EVar "nonEmptyTriples") (EListLit (ETuple (EVar "target") (EVar "tsrc") (EVar "mainWarns")))))) (DoExpr (EApp (EVar "TGOk") (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleWarnings")) (EVar "allWarns")))))))))))) (arm PWild () (EApp (EVar "TGErr") (EVar "resDiags")))))))
(DTypeSig false "parseBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))
(DFunDef false "parseBuildArgs" ((PVar "argv")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "argv")) (EListLit)) (EVar "None")) (EVar "TNative")))
(DTypeSig false "parseBuildGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget"))))))))
(DFunDef false "parseBuildGo" ((PList) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EVar "finishBuildArgs") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "-o")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EApp (EVar "Some") (EVar "v"))) (EVar "target")))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "-o"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: -o requires an argument"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--target")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") PWild) (EMatch (EApp (EVar "parseTarget") (EVar "v")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PVar "t")) () (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "t")))))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "--target"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: --target requires an argument (native|wasm)"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--allow-internal")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--keep-ir")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--json")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PVar "x") (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DTypeSig false "parseTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))
(DFunDef false "parseTarget" ((PLit (LString "native"))) (EApp (EVar "Ok") (EVar "TNative")))
(DFunDef false "parseTarget" ((PLit (LString "wasm"))) (EApp (EVar "Ok") (EVar "TWasm")))
(DFunDef false "parseTarget" ((PVar "other")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "error: unknown --target '")) (EVar "other")) (ELit (LString "' (expected native|wasm)")))))
(DTypeSig false "finishBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))))
(DFunDef false "finishBuildArgs" ((PList) PWild PWild) (EApp (EVar "Err") (ELit (LString "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>]"))))
(DFunDef false "finishBuildArgs" ((PList (PVar "input")) (PVar "out") (PVar "target")) (EApp (EVar "Ok") (ETuple (EVar "input") (EVar "out") (EVar "target"))))
(DFunDef false "finishBuildArgs" (PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: medaka build takes exactly one input file"))))
(DTypeSig false "finishRunEval" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "finishRunEval" ((PVar "target") (PVar "jsonMode") (PVar "elaborated") (PVar "mods") (PVar "cohWarns")) (EBlock (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EMatch (EApp (EVar "mainArityWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EMatch (EApp (EVar "mainNonUnitWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit)))))) (arm (PCon "None") () (EListLit)))) (DoLet false false PWild (EIf (EVar "jsonMode") (ELit LUnit) (EApp (EVar "emitWarningLines") (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleWarnings")) (EVar "cohWarns"))))) (DoLet false false PWild (EIf (EVar "jsonMode") (EApp (EApp (EVar "setRef") (EVar "pendingRunDiags")) (EApp (EVar "nonEmptyTriples") (EBinOp "++" (EVar "cohWarns") (EListLit (ETuple (EVar "target") (EApp (EVar "readFileSafe") (EVar "target")) (EVar "mainWarns")))))) (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "mainWarns")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "runJsonMode")) (EVar "jsonMode"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EVar "runProgramOutput") (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated"))))) (DoLet false false PWild (EApp (EVar "flushPendingRunDiags") (EVar "jsonMode"))) (DoExpr (EMatch (EVar "mainWarns") (arm (PList) () (ELit LUnit)) (arm (PCons PWild PWild) () (EApp (EVar "exit") (ELit (LInt 1))))))))
(DTypeSig false "flushPendingRunDiags" (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "flushPendingRunDiags" ((PCon "False")) (ELit LUnit))
(DFunDef false "flushPendingRunDiags" ((PCon "True")) (EMatch (EUnOp "!" (EVar "pendingRunDiags")) (arm (PList) () (ELit LUnit)) (arm (PVar "ts") () (EApp (EVar "ePutStrLn") (EApp (EVar "cjAllToJson") (EVar "ts"))))))
(DTypeSig false "runHelpText" (TyCon "String"))
(DFunDef false "runHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka run — Type-check and run a program (interpreter)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka run [--json] [--allow-internal] [--release] <file.mdk> [args...]\n")) (ELit (LString "\n")) (ELit (LString "  --json            emit the Diag JSON envelope for a compile-time error or\n")) (ELit (LString "                    a runtime panic, instead of human text\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --release         accepted, ignored (no-op for the interpreter path;\n")) (ELit (LString "                    kept for symmetry with `medaka build --release`)\n")) (ELit (LString "\n")) (ELit (LString "Args after <file.mdk> are passed through to the program's own `args`.\n")) (ELit (LString "Inline-eval (`-e <expr>`) is NOT supported — pass a file.\n")))))
(DTypeSig false "runRunCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runRunCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoExpr (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka run [--release] [--json] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") PWild) ((GBool (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "target")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "target")) (ELit (LString "-")))))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "medaka run: unknown flag: ")) (EVar "target")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") (PVar "progArgs")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "progArgsRef")) (EVar "progArgs"))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "parseResult") (EApp (EVar "readFileSafe") (EVar "target"))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EMethodRef "map") (EVar "dropModPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "modulePathMap")) (EVar "pathMap"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false PWild (EApp (EApp (EVar "setStdlibOwnership") (EVar "flatStdlib")) (EVar "ownedStdlib"))) (DoLet false false (PVar "perfTLoad") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "load"))) (EBinOp "-" (EVar "perfTLoad") (EVar "perfT0"))) (EVar "target"))) (DoExpr (EMatch (EVar "modsD") (arm (PList (PTuple (PVar "runMid") PWild)) () (EBlock (DoLet false false (PVar "tsrc") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "runMid")) (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods")) (EApp (EApp (EApp (EVar "cohWarnTriples") (EVar "tsrc")) (EVar "target")) (EVar "diags")))) (DoLet false false (PVar "perfTEval") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "eval"))) (EBinOp "-" (EVar "perfTEval") (EVar "perfTCheck"))) (EVar "target"))) (DoExpr (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTEval") (EVar "perfT0")))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm PWild () (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneByPath") (EVar "pathMap")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedProjectDiags") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "errText"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PTuple (PCon "None") (PVar "projWarns") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "allowInternal")) (EVar "trusted")) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "False") () (EBlock (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods")) (EVar "projWarns"))) (DoLet false false (PVar "perfTEval") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "eval"))) (EBinOp "-" (EVar "perfTEval") (EVar "perfTCheck"))) (EVar "target"))) (DoExpr (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTEval") (EVar "perfT0")))))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))))))))))))))))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "p"))))
(DTypeSig false "dropModPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropModPath" ((PTuple (PVar "mid") PWild (PVar "prog"))) (ETuple (EVar "mid") (EVar "prog")))
(DTypeSig false "modIdToPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "modIdToPath" ((PTuple (PVar "mid") (PVar "path") PWild)) (ETuple (EVar "mid") (EVar "path")))
(DTypeSig false "runProgramOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "runProgramOutput" ((PVar "preludeDecls") (PVar "modules")) (EMatch (EApp (EVar "mainTypeIsAsync") (ELit LUnit)) (arm (PCon "True") () (EApp (EApp (EVar "evalModulesOutputAsync") (EVar "preludeDecls")) (EVar "modules"))) (arm (PCon "False") () (EApp (EApp (EVar "evalModulesOutputRun") (EVar "preludeDecls")) (EVar "modules")))))
(DTypeSig false "testHelpText" (TyCon "String"))
(DFunDef false "testHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka test — Run doctests + property tests\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka test [--native | --engines eval,native] [file.mdk | dir]\n")) (ELit (LString "\n")) (ELit (LString "  --native            run doctests through a compiled native binary\n")) (ELit (LString "                      instead of the interpreter (shorthand for\n")) (ELit (LString "                      --engines native)\n")) (ELit (LString "  --engines e1,e2,...  run the listed engine set (known: eval, native);\n")) (ELit (LString "                      exit code is the AND across engines\n")) (ELit (LString "\n")) (ELit (LString "--native and --engines are mutually exclusive. With neither, the default\n")) (ELit (LString "is the interpreter (eval) alone. A file.mdk or dir target is required.\n")))))
(DTypeSig false "runTestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runTestCmd" ((PVar "argv")) (EMatch (EApp (EVar "parseTestEngines") (EVar "argv")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "engines")) () (EMatch (EApp (EVar "testTargets") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka test [--native | --engines eval,native] [file.mdk | dir]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PList (PVar "target")) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "runTestOne") (EVar "engines")) (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "runTestManyTargets") (EVar "engines")) (EListLit (EVar "target")))))) (arm (PVar "targets") () (EApp (EApp (EVar "runTestManyTargets") (EVar "engines")) (EVar "targets")))))))
(DTypeSig false "parseTestEngines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseTestEngines" ((PVar "argv")) (EMatch (ETuple (EApp (EApp (EVar "testFlagValue") (ELit (LString "--engines"))) (EVar "argv")) (EApp (EApp (EVar "hasFlag") (ELit (LString "--native"))) (EVar "argv"))) (arm (PTuple (PCon "Some" PWild) (PCon "True")) () (EApp (EVar "Err") (ELit (LString "--native and --engines are mutually exclusive; --native is shorthand for --engines native")))) (arm (PTuple (PCon "Some" (PVar "spec")) (PCon "False")) () (EApp (EVar "parseEngineList") (EVar "spec"))) (arm (PTuple (PCon "None") (PCon "True")) () (EApp (EVar "Ok") (EListLit (EVar "EngNative")))) (arm (PTuple (PCon "None") (PCon "False")) () (EApp (EVar "Ok") (EListLit (EVar "EngInterp"))))))
(DTypeSig false "parseEngineList" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseEngineList" ((PVar "spec")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EApp (EMethodRef "map") (EVar "stringTrim")) (EApp (EVar "splitLintNames") (EVar "spec"))))) (DoExpr (EMatch (EVar "names") (arm (PList) () (EApp (EVar "Err") (ELit (LString "--engines requires at least one of: eval, native")))) (arm PWild () (EApp (EVar "parseEngineNames") (EVar "names")))))))
(DTypeSig false "parseEngineNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseEngineNames" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "parseEngineNames" ((PCons (PVar "n") (PVar "rest"))) (EMatch (EApp (EVar "engineOfName") (EVar "n")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown engine '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' (known: eval, native)"))))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "e") (EVar "_s")))) (EApp (EVar "parseEngineNames") (EVar "rest"))))))
(DTypeSig false "engineOfName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Engine"))))
(DFunDef false "engineOfName" ((PLit (LString "eval"))) (EApp (EVar "Some") (EVar "EngInterp")))
(DFunDef false "engineOfName" ((PLit (LString "native"))) (EApp (EVar "Some") (EVar "EngNative")))
(DFunDef false "engineOfName" (PWild) (EVar "None"))
(DTypeSig false "testFlagValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "testFlagValue" (PWild (PList)) (EVar "None"))
(DFunDef false "testFlagValue" (PWild (PList PWild)) (EVar "None"))
(DFunDef false "testFlagValue" ((PVar "name") (PCons (PVar "a") (PCons (PVar "v") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "name")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "testFlagValue") (EVar "name")) (EBinOp "::" (EVar "v") (EVar "rest")))))
(DTypeSig false "testTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "testTargets" ((PList)) (EListLit))
(DFunDef false "testTargets" ((PCons (PLit (LString "--engines")) (PCons PWild (PVar "rest")))) (EApp (EVar "testTargets") (EVar "rest")))
(DFunDef false "testTargets" ((PCons (PLit (LString "--native")) (PVar "rest"))) (EApp (EVar "testTargets") (EVar "rest")))
(DFunDef false "testTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "testTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "testTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runTestOne" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runTestOne" ((PVar "engines") (PVar "target")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "target")) (EVar "roots"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig false "runTestManyTargets" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runTestManyTargets" ((PVar "engines") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "medaka test: no .mdk files found")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "testFilesGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "testFilesGo" (PWild PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "testFilesGo" ((PVar "engines") (PVar "rtPath") (PVar "corePath") (PVar "stdlibDir") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "f"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "f")) (EVar "roots"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EApp (EVar "not") (EVar "ok")))))))
(DTypeSig false "docHelpText" (TyCon "String"))
(DFunDef false "docHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka doc — Generate Markdown documentation for a file\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka doc <file.mdk>\n")) (ELit (LString "\n")) (ELit (LString "Prints Markdown for every PUBLIC declaration (with inferred type\n")) (ELit (LString "schemes) in <file.mdk> to stdout. Single-file only.\n")))))
(DTypeSig false "runDocCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runDocCmd" ((PVar "argv")) (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka doc [file.mdk]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") PWild) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runDoc") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target"))))))))))))))
(DTypeSig false "checkPolicyHelpText" (TyCon "String"))
(DFunDef false "checkPolicyHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka check-policy — Check a plugin's inferred effects against an allow-list\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]\n")) (ELit (LString "\n")) (ELit (LString "  --allow L1,L2,...  effect labels the plugin is permitted to use\n")) (ELit (LString "                     (default: Cache,Log)\n")) (ELit (LString "  --fn name          the function whose inferred effect row is checked\n")) (ELit (LString "                     (default: transform)\n")) (ELit (LString "\n")) (ELit (LString "Prints an accept/reject header; on accept, also runs the plugin on a\n")) (ELit (LString "sample request. Exit 0 on accept, 1 on reject.\n")))))
(DTypeSig false "runCheckPolicyCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckPolicyCmd" ((PVar "argv")) (EMatch (EApp (EVar "parsePolicyArgs") (EVar "argv")) (arm (PCon "PolicyArgs" (PCon "None") PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyArgs" (PCon "Some" (PVar "target")) (PVar "allow") (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "runCheckPolicy") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "allow")) (EVar "fn")) (arm (PCon "PolicyReject" (PVar "report")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "report"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyAccept" (PVar "report")) () (EApp (EVar "putStr") (EVar "report")))))))))))))))
(DTypeSig false "manifestHelpText" (TyCon "String"))
(DFunDef false "manifestHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka manifest — Emit a module's verified capability manifest as TOML\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka manifest <file.mdk> [--fn name]\n")) (ELit (LString "\n")) (ELit (LString "  --fn name  the function whose inferred effect row is emitted\n")) (ELit (LString "             (default: main)\n")) (ELit (LString "\n")) (ELit (LString "Prints a [package.capabilities] TOML block: one entry per effect label\n")) (ELit (LString "in the function's inferred effect row (a prefix-param becomes a string\n")) (ELit (LString "value; a Unit/top param becomes `true`).\n")))))
(DTypeSig false "runManifestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runManifestCmd" ((PVar "argv")) (EMatch (EApp (EVar "parseManifestArgs") (EVar "argv")) (arm (PCon "ManifestArgs" (PCon "None") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka manifest <file.mdk> [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "ManifestArgs" (PCon "Some" (PVar "target")) (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runManifest") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "fn"))))))))))))))
(DTypeSig false "lintHelpText" (TyCon "String"))
(DFunDef false "lintHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lint — Lint files/dirs against style rules\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka lint [paths...] [flags]\n")) (ELit (LString "\n")) (ELit (LString "  --fix                 rewrite fixable findings in-place\n")) (ELit (LString "  --json                emit the {\"files\":[...]} structured-diagnostics\n")) (ELit (LString "                       envelope instead of human text (--fix is ignored)\n")) (ELit (LString "  --cache                reuse per-file results for files whose content is\n")) (ELit (LString "                       unchanged (opt-in, like ESLint's --cache)\n")) (ELit (LString "  --disable=r1,r2,...    suppress findings from the named rules\n")) (ELit (LString "  --only=r1,...          keep only findings from the named rules\n")) (ELit (LString "  --deny=r1,...          promote findings from the named rules to error\n")) (ELit (LString "\n")) (ELit (LString "Target resolution: explicit file args are linted in order; a single\n")) (ELit (LString "directory arg lints its top-level .mdk files (not recursive); no args\n")) (ELit (LString "finds the medaka.toml project root and lints its top-level .mdk files.\n")) (ELit (LString "Exit 0 unless a SevError finding exists.\n")))))
(DTypeSig false "runLintCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintCmd" ((PVar "argv")) (EBlock (DoLet false false PWild (EApp (EVar "assertLintFlagsHaveValues") (EVar "argv"))) (DoLet false false (PVar "disableNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--disable="))) (EVar "argv"))) (DoLet false false (PVar "onlyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--only="))) (EVar "argv"))) (DoLet false false (PVar "denyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--deny="))) (EVar "argv"))) (DoLet false false (PVar "fixMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--fix"))) (EVar "argv"))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoLet false false (PVar "fileArgs") (EApp (EVar "lintTargets") (EVar "argv"))) (DoLet false false PWild (EApp (EVar "assertLintTargetsExist") (EVar "fileArgs"))) (DoLet false false (PVar "files") (EApp (EVar "resolveLintTargets") (EVar "fileArgs"))) (DoExpr (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EVar "runLintJsonCmd") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files")) (EBlock (DoLet false false (PVar "multiFile") (EMatch (EVar "files") (arm (PCons PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False")))) (DoLet false false (PVar "cacheCtx") (EApp (EApp (EVar "lintCacheCtx") (EApp (EApp (EVar "hasFlag") (ELit (LString "--cache"))) (EVar "argv"))) (EVar "fixMode"))) (DoLet false false (PTuple (PVar "perFileErr") (PVar "entries") (PVar "parsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "files")) (EVar "False"))) (DoLet false false (PVar "crossErr") (EIf (EApp (EVar "not") (EBinOp "&&" (EVar "multiFile") (EApp (EVar "not") (EVar "fixMode")))) (EVar "False") (EMatch (EVar "cacheCtx") (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "runCrossFileReportCached") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "entries"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "runCrossFileReport") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "parsed")))))) (DoLet false false PWild (EMatch (EVar "cacheCtx") (arm (PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) () (EApp (EApp (EApp (EVar "storeEntries") (EVar "cacheDir")) (EVar "stamp")) (EVar "entries"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EIf (EBinOp "||" (EVar "perFileErr") (EVar "crossErr")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit))))))))
(DTypeSig false "lintCacheCtx" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lintCacheCtx" ((PCon "False") PWild) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "True")) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "False")) (EIf (EApp (EVar "not") (EVar "crossFileCacheSound")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "root") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "canonicalizePath") (ELit (LString "."))))) (DoLet false false (PVar "stamp") (EApp (EVar "ruleSetStamp") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "stamp") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EVar "cacheDirOf") (EVar "root")) (EVar "stamp")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runLintJsonCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "runLintJsonCmd" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "files")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "cjAllToJson") (EVar "triples")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "cjLintTripleHasErr")) (EVar "triples")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))
(DTypeSig false "lintFilesToDiagTriples" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "lintFilesToDiagTriples" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagTriples" ((PVar "disable") (PVar "only") (PVar "deny") (PCons (PVar "f") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "rest"))))
(DTypeSig false "cjLintTripleHasErr" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjLintTripleHasErr" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags")))
(DTypeSig false "runCrossFileReport" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReport" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "parsed")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "parsedToTriple")) (EVar "parsed"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "triples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EMethodRef "map") (EVar "parsedToSrc")) (EVar "parsed"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportCrossFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig false "runCrossFileReportCached" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Bool")))))))
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
(DTypeSig false "lintValueFlags" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "lintValueFlags" () (EListLit (ELit (LString "--disable")) (ELit (LString "--only")) (ELit (LString "--deny"))))
(DTypeSig false "assertLintFlagsHaveValues" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertLintFlagsHaveValues" ((PVar "argv")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "f")) (EApp (EApp (EVar "contains") (EVar "f")) (EVar "argv")))) (EVar "lintValueFlags"))) (DoExpr (EIf (EBinOp "==" (EVar "bad") (EListLit)) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lint: ")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "bad")) (ELit (LString " require a value in the form --flag=<rule1,rule2,...> (a bare '")) (ELit (LString "--flag <rule>' space-separated form is not supported and would be silently")) (ELit (LString " ignored, so it is rejected instead)")))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "lintTargetExists" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "lintTargetExists" ((PVar "t")) (EMatch (EApp (EVar "listDir") (EVar "t")) (arm (PCon "Ok" PWild) () (EVar "True")) (arm (PCon "Err" PWild) () (EApp (EVar "fileExists") (EVar "t")))))
(DTypeSig false "assertLintTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertLintTargetsExist" ((PList)) (ELit LUnit))
(DFunDef false "assertLintTargetsExist" ((PVar "targets")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EVar "lintTargetExists") (EVar "t"))))) (EVar "targets"))) (DoExpr (EIf (EBinOp "==" (EVar "missing") (EListLit)) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: these targets do not exist:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "resolveLintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "resolveLintTargets" ((PList)) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoExpr (EMatch (EApp (EVar "findProjectRoot") (EVar "cwd")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths")))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit)))) (arm (PCon "Some" (PVar "root")) () (EApp (EVar "collectMdkFiles") (EVar "root")))))))
(DFunDef false "resolveLintTargets" ((PVar "targets")) (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets")))
(DTypeSig false "expandLintTarget" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expandLintTarget" ((PVar "target")) (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFiles") (EVar "target"))) (arm (PCon "Err" PWild) () (EListLit (EVar "target")))))
(DTypeSig false "lintPathJoin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "lintPathJoin" ((PVar "dir") (PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "dir")) (EBinOp "++" (EVar "dir") (EVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "collectMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFiles" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: cannot list directory ")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EListLit)))) (arm (PCon "Ok" PWild) () (EApp (EVar "sortUniqS") (EApp (EVar "collectMdkFilesRec") (EVar "dir"))))))
(DTypeSig false "collectMdkFilesRec" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFilesRec" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EApp (EVar "filterNonDot") (EVar "entries"))))))
(DTypeSig false "collectMdkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntries" (PWild (PList)) (EListLit))
(DFunDef false "collectMdkEntries" ((PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "collectMdkEntry") (EVar "dir")) (EVar "name")) (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EVar "rest"))))
(DTypeSig false "collectMdkEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntry" ((PVar "dir") (PVar "name")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "lintPathJoin") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFilesRec") (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EListLit (EVar "full")) (EListLit)))))))
(DTypeSig false "filterNonDot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonDot" ((PList)) (EListLit))
(DFunDef false "filterNonDot" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EApp (EVar "filterNonDot") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EVar "filterNonDot") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lintFilesGo" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))))
(DFunDef false "lintFilesGo" (PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (ETuple (EVar "acc") (EListLit) (EListLit)))
(DFunDef false "lintFilesGo" ((PVar "fixMode") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "cacheCtx") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EIf (EVar "fixMode") (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EApp (EVar "lintOneFileFix") (EVar "onlyNames")) (EVar "disableNames")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "entries") (PVar "parsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileReport") (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "f"))) (DoLet false false (PTuple (PVar "restErr") (PVar "restEntries") (PVar "restParsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr")))) (DoExpr (ETuple (EVar "restErr") (EBinOp "++" (EVar "entries") (EVar "restEntries")) (EBinOp "++" (EVar "parsed") (EVar "restParsed")))))))
(DTypeSig false "lintOneFileReport" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))
(DFunDef false "lintOneFileReport" ((PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "cacheCtx") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (ETuple (EVar "True") (EListLit) (EListLit))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "parsed")) (EApp (EApp (EApp (EVar "lintEntryOf") (EVar "cacheCtx")) (EVar "target")) (EVar "src"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EFieldAccess (EVar "entry") "directives")) (EFieldAccess (EVar "entry") "findings"))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "allFindings"))) (DoLet false false (PVar "srcLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (DoLet false false (PVar "output") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliLines") (EVar "srcLines")) (EVar "target")) (EApp (EVar "findingToDiag") (EVar "f"))))) (EVar "findings")))) (DoLet false false (PVar "hasOutput") (EBinOp ">" (EApp (EVar "stringLength") (EVar "output")) (ELit (LInt 0)))) (DoLet false false PWild (EIf (EBinOp "&&" (EVar "multiFile") (EVar "hasOutput")) (EApp (EVar "putStrLn") (EBinOp "++" (EVar "target") (ELit (LString ":")))) (ELit LUnit))) (DoLet false false PWild (EIf (EVar "hasOutput") (EApp (EVar "putStrLn") (EVar "output")) (ELit LUnit))) (DoExpr (ETuple (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")) (EListLit (EVar "entry")) (EVar "parsed")))))))
(DTypeSig false "lintEntryOf" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "lintEntryOf" ((PCon "None") (PVar "target") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "target")) (EVar "src")) (ELit (LString ""))) (EVar "False"))) (DoExpr (ETuple (EVar "entry") (EListLit (ETuple (EVar "target") (EVar "src") (EVar "pos") (EVar "decls")))))))
(DFunDef false "lintEntryOf" ((PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) (PVar "target") (PVar "src")) (EBlock (DoLet false false (PVar "hash") (EApp (EVar "contentHashOf") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadEntry") (EVar "cacheDir")) (EVar "stamp")) (EVar "target")) (EMethodRef "hash")) (arm (PCon "Some" (PVar "hit")) () (ETuple (EVar "hit") (EListLit))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "entry") PWild PWild) (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "target")) (EVar "src")) (EMethodRef "hash")) (EVar "True"))) (DoExpr (ETuple (EVar "entry") (EListLit)))))))))
(DTypeSig false "lintFileFresh" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "lintFileFresh" ((PVar "target") (PVar "src") (PVar "hash") (PVar "wantOccs")) (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositionsLocated") (EVar "src"))) (DoExpr (ETuple (ERecordCreate "LintEntry" ((fa "path" (EVar "target")) (fa "contentHash" (EMethodRef "hash")) (fa "findings" (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "allRules")) (EVar "target")) (EVar "src")) (EVar "pos")) (EVar "decls"))) (fa "dupOccs" (EIf (EVar "wantOccs") (EApp (EVar "fileDupOccs") (ETuple (EVar "target") (EVar "pos") (EVar "decls"))) (EListLit))) (fa "directives" (EApp (EVar "collectDirectives") (EVar "src"))) (fa "dirty" (EVar "True")))) (EVar "pos") (EVar "decls")))))
(DTypeSig false "lintOneFileFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "lintOneFileFix" ((PVar "onlyNames") (PVar "disableNames") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "newSrc") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "onlyNames")) (EVar "disableNames")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "newSrc") (EVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "fixed 0 finding(s) in ")) (EVar "target")))) (DoExpr (EVar "False"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "target")) (EVar "newSrc")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 2)))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "fixed ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) in "))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))))))
(DTypeSig false "lintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lintTargets" ((PList)) (EListLit))
(DFunDef false "lintTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "lintTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "lintTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "assertSnapshotTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertSnapshotTargetsExist" ((PVar "files")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "f"))))) (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "missing") (EListLit)) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: these targets do not exist:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "assertBlessIsScoped" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "assertBlessIsScoped" ((PVar "argv") (PVar "targets")) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "hasFlag") (ELit (LString "--bless"))) (EVar "argv"))) (EBinOp "/=" (EVar "targets") (EListLit))) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: --bless requires explicit targets — there is no whole-suite bless.")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  Name what you are approving, e.g.:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "    medaka snapshot --bless --out test/snapshots/compiler compiler/frontend/lexer.mdk")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  (or, family-aware:  sh test/diff_compiler_snapshot_frontend.sh --bless compiler/frontend/lexer.mdk)")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig false "snapshotHelpText" (TyCon "String"))
(DFunDef false "snapshotHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka snapshot — Per-stage snapshot tests\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka snapshot [--check | --new | --bless] <paths...>\n")) (ELit (LString "                  [--out <dir>] [--stages <a,b,...>] [--isolate]\n")) (ELit (LString "\n")) (ELit (LString "One mode is REQUIRED, and the three are mutually exclusive:\n")) (ELit (LString "  --check   compare against the existing snapshot; write nothing\n")) (ELit (LString "  --new     create a MISSING snapshot; never touch an existing one\n")) (ELit (LString "  --bless   rewrite an EXISTING snapshot; never create one; requires\n")) (ELit (LString "            explicit targets (no whole-suite bless)\n")) (ELit (LString "\n")) (ELit (LString "  --out <dir>       snapshot directory (default derived from MEDAKA_ROOT)\n")) (ELit (LString "  --stages a,b,...   restrict to the named stages (default: every stage)\n")) (ELit (LString "  --isolate          run one process per fixture (debug aid for a crasher)\n")) (ELit (LString "\n")) (ELit (LString "A path may be a file or directory (recursively expanded).\n")))))
(DTypeSig false "runSnapshotCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runSnapshotCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "root") (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--root"))) (EVar "argv")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))))) (DoLet false false (PVar "sel") (EApp (EVar "snapshotStages") (EVar "argv"))) (DoLet false false (PVar "targets") (EApp (EVar "snapshotTargets") (EVar "argv"))) (DoLet false false PWild (EApp (EApp (EVar "assertBlessIsScoped") (EVar "argv")) (EVar "targets"))) (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoLet false false PWild (EApp (EVar "assertSnapshotTargetsExist") (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "files") (EListLit)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka snapshot [--check|--new|--bless] [--out <dir>] [--stages <a,b,…>] <paths...>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EIf (EApp (EApp (EVar "hasFlag") (ELit (LString "--worker"))) (EVar "argv")) (EApp (EApp (EApp (EVar "runSnapshotWorker") (EVar "root")) (EVar "sel")) (EVar "files")) (EMatch (EApp (EVar "snapshotMode") (EVar "argv")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: pass --check (verify), --new (create missing snapshots) or --bless (rewrite existing ones)")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Some" (PVar "mode")) () (EBlock (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSnapshotSupervisor") (EVar "root")) (EVar "mode")) (EApp (EApp (EVar "hasFlag") (ELit (LString "--isolate"))) (EVar "argv"))) (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--out"))) (EVar "argv"))) (EVar "sel")) (EVar "files"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))))))))
(DTypeSig false "snapshotMode" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "SnapMode")))))
(DFunDef false "snapshotMode" ((PVar "argv")) (EBlock (DoLet false false (PVar "modes") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EApp (EVar "hasFlag") (EVar "f")) (EVar "argv")))) (EListLit (ELit (LString "--check")) (ELit (LString "--new")) (ELit (LString "--bless"))))) (DoExpr (EMatch (EVar "modes") (arm (PList (PLit (LString "--check"))) () (EApp (EVar "Some") (EVar "SnapCheck"))) (arm (PList (PLit (LString "--new"))) () (EApp (EVar "Some") (EVar "SnapNew"))) (arm (PList (PLit (LString "--bless"))) () (EApp (EVar "Some") (EVar "SnapBless"))) (arm (PList) () (EVar "None")) (arm (PVar "many") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "many")))) (ELit (LString " are mutually exclusive — pick one."))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EVar "None"))))))))
(DTypeSig false "snapshotStages" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "snapshotStages" ((PVar "argv")) (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--stages"))) (EVar "argv")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "spec")) () (EMatch (EApp (EVar "parseStages") (EVar "spec")) (arm (PCon "Ok" (PVar "names")) () (EVar "names")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit))))))))
(DTypeSig false "snapshotTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "snapshotTargets" ((PList)) (EListLit))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--out")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--root")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--stages")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "snapshotTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "snapshotTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "snapFlagValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "snapFlagValue" (PWild (PList)) (EVar "None"))
(DFunDef false "snapFlagValue" (PWild (PList PWild)) (EVar "None"))
(DFunDef false "snapFlagValue" ((PVar "name") (PCons (PVar "a") (PCons (PVar "v") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "name")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "snapFlagValue") (EVar "name")) (EBinOp "::" (EVar "v") (EVar "rest")))))
(DTypeSig false "dirOf2" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf2" ((PVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo2" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo2" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo2" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "replUsageLine" (TyCon "String"))
(DFunDef false "replUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka repl — Start the interactive REPL\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka repl     Start an interactive session that reads expressions\n")) (ELit (LString "                 from stdin, evaluates them, and prints results until\n")) (ELit (LString "                 stdin closes (EOF) or you enter :quit.\n")))))
(DTypeSig false "runReplCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runReplCmd" ((PList)) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "preludeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false PWild (EApp (EApp (EVar "initSession") (EVar "runtimeDecls")) (EVar "preludeDecls"))) (DoExpr (EApp (EVar "replLoop") (ELit LUnit)))))))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka repl: unknown option '")) (EVar "bad")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "lspUsageLine" (TyCon "String"))
(DFunDef false "lspUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lsp — Run the Language Server Protocol server over stdio\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka lsp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an LSP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n")))))
(DTypeSig false "runLspCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspCmd" ((PList)) (EApp (EVar "runLspServerFromEnv") (ELit LUnit)))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lsp: unknown option '")) (EVar "bad")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "runLspServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EApp (EApp (EVar "runServer") (EVar "rsrc")) (EVar "csrc")))))))))
(DTypeSig false "mcpUsage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "mcpUsage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka mcp — Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka mcp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an MCP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n"))))))
(DTypeSig false "runMcpCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpCmd" ((PList)) (EApp (EVar "runMcpServerFromEnv") (ELit LUnit)))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "mcpUsage") (ELit LUnit))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "mcpUsage") (ELit LUnit))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka mcp: unknown argument '")) (EVar "bad")) (ELit (LString "' (mcp takes no arguments; try 'medaka mcp --help')"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "runMcpServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EApp (EApp (EApp (EApp (EVar "runMcpServer") (EVar "rsrc")) (EVar "csrc")) (EVar "stdlibDir")) (EVar "sourceStalenessVerdict")))))))))
