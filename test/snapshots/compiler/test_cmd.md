# META
source_lines=3941
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/test_cmd.mdk — `medaka test` logic (doctests + property tests),
-- factored out of test_main.mdk so BOTH the interpreted driver (test_main.mdk)
-- and the native CLI (medaka_cli.mdk's runTestCmd) share one implementation.
--
-- Exports:
--   runTest runtimeP coreP target roots   read the three sources + drive
--   rootsOrDefault target roots           default roots to [dirOf target]
--   dirOf path                            dirname on a POSIX path
--
-- Mirrors `./_build/default/bin/main.exe test <file.mdk>` byte-for-byte for the
-- doctest phase and (passing) prop phase:
--
--   running doctests in <file>
--     ok   <file>:<line>: <input>
--     FAIL <file>:<line>: <input>
--          expected: <e>
--            actual: <a>
--     ERROR <file>:<line>: <input>
--           <msg>
--   <blank>
--   <file>: P/T passed[ (F failed, E errors)]
--   Testing "<prop>" ... OK (100 tests)        -- prop phase, only if props exist
--   <blank>
--   N passed, M failed
--
-- The doctest/prop phases route EVERY file through the multi-module path
-- (DRIVER-COLLAPSE Phase 1+3): a no-import file uses the degenerate 1-module case
-- (elaborateOne/elaborateModules over [(rootId, decls)] + evalOne/
-- evalModulesRootEnv); an import-bearing file loads its real sibling graph
-- (the located loader + elaborateModules + evalModules), so cross-module
-- instances/values resolve.  Neither path calls the flat
-- elaborateDict/evalProgram anymore.  An import-bearing target loads and
-- elaborates its graph exactly ONCE per invocation: `prepareMulti` owns that
-- load, that elaboration and the typecheck gate derived from it.
-- ARCH E-5 (#1521, owns #1223): `rootId` is `canonicalPathId deps roots target`
-- — the SAME canonicalized id a sibling's `import <name>` resolves to when it
-- reaches this file through the loader (`canonicalModId`'s
-- last-containing-root, round-trip-guarded convention — NOT plain
-- `moduleIdOfPath`'s first-root, which agrees with it only when a project has
-- one root; a target below its own `medaka.toml` is the case that needs the
-- distinction, see `canonicalPathId`'s own comment in `driver/loader.mdk`), so a
-- module that is simultaneously a test target and a sibling's import dependency
-- carries one identity, not two — REGARDLESS of whether the two files share a
-- directory: `canonicalPathId`'s last-containing-root convention depends only
-- on the SET OF ROOTS each file's own `entrySearchRoots` walk reaches (both
-- walk up to the SAME `medaka.toml`, wherever each file sits under it), not on
-- the two files being siblings in one directory.  The retired nested-origin
-- fixture was the CROSS-DIRECTORY witness: its main sat at the fixture root
-- and its leaf was nested a directory below it, and the two agreed.
-- Previously this was the synthetic literal `"__user__"`, hardcoded at every
-- single-file call site below.

import frontend.ast.{Decl(..), Expr, Loc(..), Ty}
import frontend.parser.{parse, parseLocated, parseResult}
import frontend.desugar.{desugar}
import frontend.desugar_cache.{desugaredPrelude, desugaredPreludeKey}
import driver.loader.{
  loadProgramFilesLocatedE,
  modIdToPath,
  loadErrorMessage,
  LoadError(..),
  entrySearchRoots,
  canonicalPathId,
  readDeps,
  findProjectRoot,
  findProjectRootOrSelf,
  readSource,
}
import driver.build_cmd.{readPreludeFile, envOr, defaultMedakaRoot}
import types.typecheck.{
  elaborateOne, elaborateModules, TcDiag(..), tcDiagGoalKey
}
import types.route_key.{withEvidencePreserved}
import backend.private_mangle.{mangleCtorCollisionsPair}
import frontend.marker.{declRefs}
import frontend.lexer.{collectComments}
import eval.eval.{
  Value,
  EvalEnv,
  evalOneRootEnvWith,
  evalModulesRootEvalEnvWith,
  evalModulesRootEnvWith,
  currentEvalFile,
  modulePathMap,
  testCapableExterns,
  funNamesOf,
  dropShadowedExp,
  lookupBinding,
  force,
  ppValue,
}
import tools.doctest.{
  Example,
  ExResult(..),
  RunResult(..),
  Engine(..),
  engineName,
  extractExamples,
  buildSynthResults,
  buildSynthDecls,
  buildDetailsFrom,
  doctestFailSuffix,
  hasUseDecls,
  printDoctestDetails,
  runDetails,
  runPassed,
  runFailed,
  runErrors,
  exampleInput,
  exampleLine,
  synthName,
  exResultJsonFields,
}
import tools.native_doctest.{runNativeDoctests}
import tools.native_test_decls.{runNativeTests}
import tools.native_props.{runNativePlannedPropRequests}
import tools.prop_plan.{
  PlanModule(..),
  CustomPlan(..),
  GenPlan,
  PlanEnv,
  PlanError(..),
  PlanErrorReason(..),
  customPlansReachable,
  planErrorText,
}
import tools.prop_runner.{
  hasProps,
  runAllPlannedPropRequestsResults,
  preparePlannedPropRequests,
  runPreparedPropRequestsResults,
  PreparedPropRequest(..),
  PropHelper(..),
  PropResult(..),
  PropStatus(..),
  PropFailureKind(..),
  PropRequest(..),
  filterProps,
  filterPropsByName,
  propResultName,
  propResultPassed,
  propResultDetail,
  propResultEngine,
  propResultStatus,
  propResultSeed,
  propResultCases,
  propResultFailureKind,
  propSeedValue,
}
import tools.prop_helpers.{PropHelpers(..), propHelpersForPlans}
import tools.eval_props.{
  emitEvalPropRows,
  decodeEvalPropRows,
  propResultJson,
  propFailureKindJson,
  startEvalPropWorker,
  takeEvalPropBootstrap,
}
import tools.probe_transcript.{firstNonEmptyLine}
import tools.test_pins.{
  PinIndex,
  PinKind(..),
  TestExpectedFailure(..),
  TestPin,
  buildPinIndex,
  pinFromIndex,
  validatePinNames,
}
import tools.test_pins_io.{loadPinContext}
import tools.test_pins_report.{
  GradedProp,
  GradedTest,
  gradeProps,
  gradeTests,
  gradedPropPassed,
  gradedTestPassed,
  gradedPropRaw,
  gradedTestRaw,
  gradedPropVerdict,
  gradedTestVerdict,
  knownRedCountProps,
  knownRedCountTests,
  gradedPropStatus,
  gradedPropRawStatus,
  gradedPropIssue,
  gradedPropPinDetail,
  gradedTestStatus,
  gradedTestRawStatus,
  gradedTestIssue,
  gradedTestPinDetail,
}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omInsert, omKeys, omLookup}
import tools.test_runner.{
  collectTests, exprLine, runOneTestEnv, hasTests, uncapableExternsEnv
}
import driver.diagnostics.{
  analyzeLocated,
  projectDiagsFromTc,
  projectDiagsLoaded,
  noStdlibExports,
  chainKeyOf,
  desugaredModPairs,
  mkDiag,
  Severity(..),
  readDiagSrc,
  ppDiagCliSrc,
  ppDiagCliLines,
  srcLinesArr,
  parseErrDiag,
  Diag,
  diagIsError,
}
export import support.util.{rootsOrDefault}
import support.util.{
  listLen,
  joinNl,
  isNonEmptyL,
  filterList,
  endsWith,
  splitOnChar,
  contains,
  joinWith,
  splitNl,
  startsWith,
  stringTrim,
  reverseL,
  anyList,
}
import support.path.{dirOf, baseOf, joinPath}
import args.{
  ArgSpec, Args, spec, switch, value, internal, flag, flagValue, withStrictDash
}
import json.{Json(..), jObject, jArray, stringify}
import tools.lint.{splitLintNames}
import string.{toInt}

-- `medaka test --filter <substring>`: does `needle` occur anywhere in
-- `haystack`? Same tiny definition as `prop_runner.mdk`'s copy — not shared
-- via support/util.mdk to keep this slice's snapshot bless scoped to the
-- files it names.
substringMatch : String -> String -> Bool
substringMatch needle haystack = isSome (stringIndexOf needle haystack)

-- Returns True iff every doctest AND every prop passed.  A file that parses
-- clean with zero doctests/props is vacuously True (nothing ran, nothing
-- failed).  A read error — on either prelude source OR the target itself —
-- returns False (P0-212): a file that couldn't even be opened is a FAILURE,
-- not a vacuous pass, so callers that gate `exit 1` on this Bool (rather than
-- on the printed report, since the report is prose, not a signal) see it.
-- `engines` selects which execution engine(s) run the doctest and `test "…"`
-- phases — `[EngNative]` (the default, what `medaka build` would produce),
-- `[EngInterp]` under `--engines eval`, or an explicit `--engines eval,native`
-- list. It has NO effect on the prop phase, which is interpreter-only.
-- `cases` overrides the prop sample count (`--cases`, default 100 at the CLI);
-- `filterOpt` restricts doctests/`test "…"`/`prop "…"` to names containing a
-- substring (`--filter`, #2295).
export
runTest : List Engine ->
  String ->
  String ->
  String ->
  List String ->
  Int ->
  Option String ->
  <IO> Bool
runTest engines runtimeP coreP target roots cases filterOpt =
  match readPreludeFile runtimeP
    Err e =>
      let _ = ePutStrLn e
      False
    Ok rsrc => match readPreludeFile coreP
      Err e =>
        let _ = ePutStrLn e
        False
      Ok csrc => match readSource target
        Err e =>
          let _ = ePutStrLn e
          False
        -- A FILE-LEVEL parse error in the target must surface as the SAME located
        -- `file:L:C:` diagnostic `medaka check` prints — not the unlocated
        -- `panic "parse error"` the bare `desugar (parse tsrc)` below would raise
        -- (issue #892).  Route through the non-panicking `parseResult` first (the
        -- exact gate `check` uses) and, on failure, render the structured
        -- `ParseError` through the shared `parseErrDiag`/`ppDiagCliSrc` machinery,
        -- returning False so the caller exits nonzero — accumulate-and-report, not
        -- panic.  (Issue #55 fixed parse errors in an individual doctest EXAMPLE;
        -- this covers a parse error in the module SOURCE itself.)
        Ok tsrc => match parseResult tsrc
          Err e =>
            let _ = ePutStrLn (ppDiagCliSrc tsrc target (parseErrDiag target e))
            False
          Ok _ =>
            let userDecls = desugar (parse tsrc)
            let exempt = typecheckExempt target userDecls tsrc
            let _ = exemptNotice exempt target userDecls
            match pinIndexForTarget target userDecls
              Err err =>
                let _ = ePutStrLn err
                False
              Ok (file, index) =>
                -- S-1/#2234 (F-converge): the prelude halves go through the
                -- content-keyed `desugaredPrelude` memo; only the USER source is
                -- parsed+desugared fresh here.
                driveAll
                  engines
                  (desugaredPrelude rsrc)
                  (desugaredPrelude csrc)
                  rsrc
                  csrc
                  target
                  tsrc
                  roots
                  cases
                  filterOpt
                  userDecls
                  exempt
                  file
                  index

pinIndexForTarget : String -> List Decl -> <IO> Result String (String, PinIndex)
pinIndexForTarget target userDecls = do
  context <- loadPinContext target
  let names =
    validatePinNames
      context.contextPins
      context.contextFile
      (propNamesOf userDecls)
      (testNamesOf userDecls)
  match names
    Err err => Err err
    Ok () =>
      map
        (index => (context.contextFile, index))
        (buildPinIndex context.contextPins)

-- ── typecheck gate (issues #260, #1229) ──────────────────────────────────────
-- `medaka test` must not GREEN-LIGHT a module whose DOCTESTS `medaka check`
-- REJECTS: the doctest driver ELABORATES the module (dict-passing) but never
-- surfaces the accumulated type errors, so a module with type errors — even ones
-- in functions no doctest exercises — passes `test` while `check` fails
-- (test-green / check-dies, the repo's #1 bug class inverted).  So type-check the
-- whole module FIRST — exactly the way `medaka
-- check` does — and fail the run (before running any example) if it doesn't check.
--
-- ⚠️ The EXEMPTION is `test "…"` / `prop "…"`-BEARING modules, NOT "everything
-- without a doctest" (issue #1229 narrowed it).  Those two phases DELIBERATELY
-- exercise eval on constructs the type checker rejects — the ported
-- eval-regression corpus (`test/ported/*.mdk`, run by `diff_compiler_ported.sh`)
-- has 0 doctests and 200+ `test "…"` assertions over `let rec` non-function RHSs,
-- `deriving (Num)`, ambiguous instances resolved by eval's arg-tag, etc.  Gating
-- those would break a suite whose entire point is eval-vs-check divergence.
--
-- ── issue #1229: the zero-doctest hole ──────────────────────────────────────
-- The exemption must not be keyed on doctests ALONE (`[] => None`): a module
-- with NO test-facing construct of any kind — no doctest, no `test "…"`, no
-- `prop "…"` — skips the gate too, prints `(no doctests found)` and exits 0
-- WITHOUT EVER BEING TYPE-CHECKED: `medaka test broken.mdk` reported success on
-- source `medaka check` rejects.  That shape has no eval-vs-check-divergence
-- rationale to preserve (there is nothing for eval to run), so it is gated now.
-- A module that type-checks and declares no tests still exits 0 with the same
-- `(no doctests found)` report — the run is no longer vacuous, it type-checked
-- the file.  It is NOT the "a gate that ran nothing must never report green"
-- case: a source file with no tests is a legitimate steady state, not a phantom
-- skip, and it is the OVERWHELMING majority of the tree — so a nonzero exit here
-- would make `medaka test <dir>` permanently red on any real project.  Derive
-- the majority rather than trusting a number in a comment:
--   for f in $(git ls-files '*.mdk'); do grep -qE '^[[:space:]]*(-- )?> ' "$f" && continue
--     grep -qE '^[[:space:]]*(prop|test) "' "$f" || echo "$f"; done | wc -l
-- (2807 of 2886 tracked `.mdk` files, measured 2026-08-09.)
-- ⚠️ That `(-- )?` is NOT optional polish.  `isInputLine` (tools/doctest.mdk) tests
-- `startsWith "-- > "` AFTER `expandBlock`/`expandLines` have trimmed each inner line
-- of a `{- … -}` lexeme and RE-PREFIXED it with `"-- "`, so a bare `> expr` inside a
-- block comment is a doctest too — and that is the DOMINANT form in stdlib.  A
-- line-comment-only `grep -- '-- >'` scores stdlib/list.mdk at 0 doctests when it has
-- 123, and mis-reports the exempt set as 36 files (including core/list) when it is 18.
-- `isInputLine` + `expandBlock` are the authority; the grep above is an approximation
-- of them, not a second definition.
--
-- ⚠️ PRECEDENCE: doctest presence WINS over the `test`/`prop` exemption — the first
-- guard below is checked first, so a module carrying BOTH is type-checked.  That is
-- deliberate (#260's fix must not be weakened by adding one `test "…"` decl) and it
-- is load-bearing for 24 tracked files that carry both, stdlib/{core,list,map,json,
-- array,…} among them — i.e. most of the stdlib would silently stop being gated if
-- the guards were reordered.  Derive that set the same block-aware way:
--   for f in $(git ls-files '*.mdk'); do grep -qE '^[[:space:]]*(-- )?> ' "$f" || continue
--     grep -qE '^[[:space:]]*(prop|test) "' "$f" && echo "$f"; done
--
-- ── issue #1680: the exemption must not be SILENT ────────────────────────────
-- The exemption above is settled and stays.  What was wrong is that it was
-- INVISIBLE: `medaka test` on
--     f : Int -> Int
--     test "t" = f "x" == 3
-- skipped the type checker without saying so and then died with a bare
-- `runtime error [E-PANIC]: unknown op '+'` — a type error rendered as an
-- interpreter crash, with nothing in the output connecting the two.  So the
-- exempted arm now ANNOUNCES itself on stderr (`typecheckSkipNotice`) before the
-- run proceeds: which module was not type-checked, which disjunct of the
-- predicate exempted it, and the `medaka check` command that WILL type-check it.
-- This is deliberately a note, not a failure — exit codes are unchanged, because
-- test/ported/*.mdk must keep exiting 0.
-- ⚠️ It goes to STDERR, not stdout: the doctest/prop/test reports on stdout are
-- parsed for counts by `test/diff_compiler_ported.sh`, and a line injected into
-- that stream would be graded as report text.  (The in-language floor gates read
-- `--json`'s `summary.passed`, not this stream.)  `ported` classifies stderr by
-- `^runtime error \[E-PANIC\]`, which this note cannot match.
-- The exemption PREDICATE alone, with no side effect — shared by the printing
-- CLI arm (`runTest`, which pairs it with `exemptNotice`) and the silent,
-- data-returning arm `runTestReport`/`medaka mcp`'s `medaka_test` uses (#1443).
-- Doctest presence still wins over the `test`/`prop` exemption (same precedence
-- as before the factor-out).
--
-- The exemption suppresses the VERDICT, not the typecheck: the phases evaluate
-- trees that come out of an elaboration, so an exempt module is still
-- elaborated — its diagnostics are simply not rendered, and it runs.  Exit
-- codes and both streams are unchanged by the exemption.
--
-- #1445/#2513: the exemption is narrowed by PATH, not just by decl shape —
-- `isNewVehiclePath` below excludes the `[P-TEST-SIBLING]` `*_test.mdk`
-- convention (AGENTS.md) so a test sibling that lives in the tree — under
-- `compiler/`/`stdlib/`, or in a real project's own `test/` directory — is
-- always type-checked, never silently swallowed the way `test/ported/*.mdk`
-- deliberately still is.
typecheckExempt : String -> List Decl -> String -> <IO> Bool
typecheckExempt target userDecls tsrc
  | isNonEmptyL (extractExamples (collectComments tsrc)) = False
  | isNewVehiclePath target = False
  | otherwise = hasProps userDecls || hasTests userDecls

-- The `[P-TEST-SIBLING]` convention (AGENTS.md): a `*_test.mdk` sibling is the
-- in-tree test vehicle (S-2), and must not inherit the `test`/`prop` exemption
-- meant for the eval-vs-check divergence corpus (`test/ported/*.mdk`) — that
-- corpus predates the convention and keeps the exemption unchanged, which it
-- does for free: not one of its files carries the `_test.mdk` suffix
-- (`git ls-files 'test/ported/*_test.mdk'` is empty).
--
-- The rule is the suffix AND one of two path shapes: a `compiler`/`stdlib`
-- SEGMENT, or a real project's own `test/` directory.  The suffix alone is too
-- wide — it also claims a scratch or synthetic `*_test.mdk` that belongs to no
-- project at all, and a directory that merely CONTAINS the text `compiler` or
-- `stdlib` in its name.
--
-- The segment half is a `/`-delimited SEGMENT match over the CANONICALIZED
-- target, not a substring test over the string the CLI was handed.  Both halves
-- are load-bearing, and a bare `substringMatch "compiler/"` got each one wrong
-- in the opposite direction:
--   • canonicalization, because the classification must not depend on the
--     invocation FORM.  `medaka test compiler/types/x_test.mdk` and, from
--     inside that directory, `medaka test x_test.mdk` name the same module; the
--     second carries no `compiler/` substring, so the substring form silently
--     re-exempted the file the convention exists to guard.
--   • segment matching, because `compiler`/`stdlib` must be real path
--     components.  A tree under `…/mycompiler/…` or `…/newstdlib/…` contains
--     the substring without containing the directory.
-- `canonicalizePath` returns its input unchanged on an unresolvable path, so an
-- already-relative, already-`compiler/`-rooted target still classifies the same.
--
-- The project half (`underProjectTestDir`) covers the vehicles that live
-- outside `compiler/`/`stdlib/` — `pds/test/*_test.mdk`,
-- `sqlite/test/*_test.mdk` and any future project's — which are ordinary
-- type-checkable code, not eval-vs-check divergence corpora: gating all 26
-- tracked `*_test.mdk` files outside `compiler/`/`stdlib/` surfaced four type
-- errors, every one of them ordinary (a missing `deriving`, an unimported type
-- name, an under-general signature, an unannotated ambiguous literal).  It asks
-- the filesystem instead of consulting a roster, so a project added later is in
-- scope with no edit here ([W-PROJECT-BY-MANIFEST]) — the same live derivation
-- `test/preflight.sh` and `test/diff_compiler_project_enrolment.sh` use.
--
-- The third half (`underMedakaRepoTestDir`) is this repository's OWN `test/`
-- directory, which the project half cannot reach: the medaka repo root carries
-- no `medaka.toml` of its own (`compiler/` and each sibling project has one,
-- the root does not), so `findProjectRoot` walks past it to the filesystem root
-- and answers `None`.  The repo's `test/*_test.mdk` gate-tests are ordinary
-- type-checkable code by the same argument as any project's, and were the last
-- `*_test.mdk` files still inheriting the exemption (#2679).  It too asks the
-- filesystem — the `test/` directory whose SIBLING is the compiler project —
-- rather than naming a root.
isNewVehiclePath : String -> <IO> Bool
isNewVehiclePath target =
  if endsWith "_test.mdk" target then
    let canon = canonicalizePath target
    hasVehicleSegment canon
      || underProjectTestDir canon
      || underMedakaRepoTestDir canon
  else
    False

-- Is `compiler` or `stdlib` a whole `/`-delimited component of `path`?
hasVehicleSegment : String -> Bool
hasVehicleSegment path =
  isNonEmptyL
    (filterList
      (seg => seg == "compiler" || seg == "stdlib")
      (splitOnChar '/' path))

-- Does `target` sit directly in the `test/` directory of a REAL project — a
-- directory named exactly `test` with a `medaka.toml` at or above it?  The
-- manifest is what makes it a project ([W-PROJECT-BY-MANIFEST]); WHICH project
-- is irrelevant, so nothing here enumerates them.  A scratch tree with no
-- manifest anywhere above it answers `None` and keeps the exemption.
--
-- Takes the CANONICAL path, like its two siblings above.  `baseOf (dirOf p)`
-- is a spelling test, so on a raw argument `test/./x_test.mdk` answers `.`
-- rather than `test` and the exemption survives a path a user can type by
-- accident -- the same file, addressed two ways, typechecked one way and not
-- the other.
underProjectTestDir : String -> <IO> Bool
underProjectTestDir target =
  let d = dirOf target
  if baseOf d == "test" then match findProjectRoot d
    Some _ => True
    None => False
  else
    False

-- Does `target` sit directly in the medaka repository's own `test/` directory?
-- That directory has no manifest at or above it, so `underProjectTestDir`
-- cannot see it; what identifies it instead is its SIBLING — a `test/` whose
-- parent also holds the compiler project's `medaka.toml` is this tree's `test/`
-- and no other.  Derived, not a roster, and worktree-local: it answers about
-- the checkout the target lives in, not about the one the running binary was
-- built from.
--
-- The direct-child rule matters: `test/ported/*.mdk` sits a directory deeper
-- (its `dirOf` is `…/test/ported`), so the eval-vs-check divergence corpus is
-- untouched and keeps its exemption.
underMedakaRepoTestDir : String -> <IO> Bool
underMedakaRepoTestDir target =
  let d = dirOf target
  baseOf d == "test" && fileExists (joinPath (dirOf d) "compiler/medaka.toml")

-- The exemption ANNOUNCEMENT, on the printing arm only (#1680).  The silent
-- twin (`runTestReport`, for MCP/`--json`) has no stderr channel of its own and
-- makes the same decision without it.
exemptNotice : Bool -> String -> List Decl -> <IO> Unit
exemptNotice False _ _ = ()
exemptNotice True target userDecls =
  ePutStrLn (typecheckSkipNotice target userDecls)

-- Type-check the module the way `medaka check` does.  Prelude-only (no
-- non-core imports) modules go through `analyzeLocated`, the single-file
-- analyzer `medaka check` uses: it correctly handles the target==prelude case
-- (`medaka test stdlib/core.mdk`, the neq-hang canary) via the shared
-- shadow-scoping, and is UNGUARDED for internal-only externs so a stdlib
-- module that calls `arrayGetUnsafe` &co. is not spuriously rejected.
-- Import-bearing modules are gated by `gateOfPerModule` below instead, off the
-- ONE elaboration the phases already need.
-- Returns Some <located error text> iff the module does NOT typecheck, else None.
singleFileTypeErrors : String -> String -> String -> String -> Option String
singleFileTypeErrors target tsrc rsrc csrc =
  let errs = filter diagIsError (analyzeLocated noStdlibExports rsrc csrc tsrc)
  match errs
    [] => None
    _ => Some (joinNl (map (ppDiagCliLines (srcLinesArr tsrc) target) errs))

-- #1362: `singleFileTypeErrors` above uses the UNGUARDED `analyzeLocated` (no
-- internal-extern restriction) so a stdlib module under test is never
-- spuriously rejected; the multi-module gate is unguarded too
-- (`allowInternal = True`, `trustedMods = []`) for the same reason — `medaka
-- test` is not the internal-extern enforcement surface (`check`/`--json` is).
--
-- It reads the per-module diagnostics of the elaboration the three phases
-- share, and routes them through `projectDiagsFromTc` — `analyzeProject`'s own
-- resolve + bucketing half, called with these diagnostics in place of a second
-- whole-graph typecheck — so the gate's verdict is bucketed, filtered and
-- rendered by exactly the machinery that produced it before.
gateOfPerModule : Bool ->
  List Decl ->
  List Decl ->
  List (String, String, List Decl) ->
  List (String, (List TcDiag, List TcDiag)) ->
  <IO> Option String
gateOfPerModule True _ _ _ _ = None
gateOfPerModule False runtimeDecls coreDecls mods perModule =
  renderGate
    (projectDiagsFromTc
      noStdlibExports
      True
      []
      runtimeDecls
      coreDecls
      mods
      perModule)

-- A load failure reaches the gate as the diagnostic `analyzeProject` attributes
-- to it: a parse failure to the module that owns it, anything else (unknown
-- module, cycle, unreadable file) to the entry.
loadGate : Bool -> String -> LoadError -> <IO> Option String
loadGate True _ _ = None
loadGate False target le = renderGate (loadErrorDiags target le)

loadErrorDiags : String -> LoadError -> List (String, List Diag)
loadErrorDiags _ (LoadParseFailed mpath _ pe) =
  [(mpath, [parseErrDiag mpath pe])]
loadErrorDiags target (LoadCycle e cpath csite) = match csite
  Some (_, loc) => [(cpath, [mkDiag SevError "R-MODULE-LOAD" e (Some loc)])]
  None => [(target, [mkDiag SevError "R-MODULE-LOAD" e None])]
loadErrorDiags target (LoadMsg e) =
  [(target, [mkDiag SevError "R-MODULE-LOAD" e None])]

renderGate : List (String, List Diag) -> <IO> Option String
renderGate results = match flatMap renderFileErrors (map readDiagSrc results)
  [] => None
  rendered => Some (joinNl rendered)

renderFileErrors : (String, String, List Diag) -> List String
renderFileErrors (path, src, diags) =
  -- #2044: split the source ONCE, not once per diagnostic.
  map (ppDiagCliLines (srcLinesArr src) path) (filter diagIsError diags)

typecheckGateFail : String -> String -> String
typecheckGateFail target errText =
  "type error in \{target} — `medaka test` requires it to `medaka check` first:\n\{errText}"

-- The announcement for the `test "…"`/`prop "…"` exemption (issue #1680).  Names
-- the module, the disjunct of `hasProps || hasTests` that exempted it, and the
-- command that DOES type-check it, so an ensuing interpreter panic is readable as
-- the possible uncaught type error it may be.
typecheckSkipNotice : String -> List Decl -> String
typecheckSkipNotice target userDecls =
  "note: typechecking was skipped for \{target}\n  reason: the module declares \{skipReasonDecls userDecls} and no doctests, so `medaka test` exempts it from the type checker (issue #1229) — those phases exist to exercise eval on constructs `medaka check` rejects.\n  a runtime error below may therefore be an uncaught TYPE error.\n  to type-check it: medaka check \{target}"

-- Which disjunct of the exemption predicate fired.  Both are reported when both
-- hold: the two are independent reasons and a reader debugging one should not be
-- told only about the other.
skipReasonDecls : List Decl -> String
skipReasonDecls userDecls
  | hasTests userDecls && hasProps userDecls =
    "`test \"…\"` and `prop \"…\"` decls"
  | hasTests userDecls = "`test \"…\"` decls"
  | otherwise = "`prop \"…\"` decls"

-- #2340: `--filter <sub>` matching NOTHING across all three phases (doctests,
-- props, `test "…"`) would otherwise report `0/0 passed` and exit 0 — a filter typo
-- would look identical to a genuinely clean run. A module that declares zero
-- doctests/props/tests to begin with (no `--filter` involved, or `--filter`
-- given but every phase was already empty) stays the existing vacuous pass
-- (P0-212, `test_cmd.mdk`'s zero-doctest note above) — this only fires when a
-- filter was GIVEN and matched nothing anywhere.
export
filterMatchedNothing : Option String -> String -> List Decl -> Bool
filterMatchedNothing None _ _ = False
filterMatchedNothing (Some sub) tsrc userDecls =
  not
    (isNonEmptyL
        (filterExamplesByName
          (Some sub)
          (extractExamples (collectComments tsrc)))
      || isNonEmptyL (filterPropsByName (Some sub) (filterProps userDecls))
      || isNonEmptyL (filterTestsByName (Some sub) (nativeRawTests tsrc)))

-- ── one load, one elaboration per invocation ────────────────────────────────
-- An import-bearing target loads its graph once, with the LOCATED loader, and
-- the three phases share one elaboration of it.  The located loader is not
-- optional: a diagnostic raised while a phase EVALUATES — a doctest panic, an
-- ambiguous dispatch — carries the span of the tree it was evaluating, so the
-- placeholder-loc `loadProgram` renders those as `:0:0:`.  Where the gate's
-- verdict comes from is `prepareMulti`'s own question, answered below.
--
-- The synth `__dt_i__` bindings are ordinary top-level `DFunDef`s and the prop
-- and `test "…"` phases select their bodies by decl SHAPE out of the elaborated
-- root module, so sharing the injected trees with them is inert; the injection
-- is empty for a module with no doctests.
--
--   TestPair runtime rawCore core raw mods  loaded source declarations paired with the
--                                   elaborated, ctor-mangled graph every phase
--                                   evaluates
--   TestPairErr msg     a loader failure standing in for it, so each phase
--                       reports it exactly as it always has
data TestPair =
  | TestPair (List Decl) (List Decl) (List Decl) (List (String, List Decl)) (List (String, List Decl))
  | TestPairErr String

-- Helper elaboration is a second, temporary graph elaboration used only by
-- custom Arbitrary property parameters.  It carries the reduced helper graph
-- and the route words whose helpers the typechecker rejected.
data HelperValidation =
  | HelperValidation TestPair (List PropHelper) (OrdMap String) (Option String)

-- What the DOCTEST phase's interpreter arm evaluates.  The two shapes are NOT
-- interchangeable, which is why this is a separate type rather than a third
-- `TestPair` constructor: the single-file arm hands `evalOneRootEnvWith` an EMPTY
-- prelude with core folded into one `__main__` unit, so prelude-shadow splitting
-- and cross-unit constructor mangling both see a different program than the pair
-- form's core-beside-modules shape does.
--
-- `DtSingle` carries the INPUTS, not a tree: the single-file elaboration must
-- not happen for a module that declares no doctests, and `runChosen` is the
-- first point that knows there are examples to run.
data DoctestTrees =
  | DtPair TestPair
  | DtSingle (List Decl) (List Decl) String (List String) (List Decl)

-- What `prepareMulti` hands back beside the gate verdict.  On the no-doctest
-- arm, and on a load failure, the trees are already in hand — the elaboration
-- that produced the gate IS the phases' input.  On the doctest arm the gate is a
-- separate pass, so the phases' elaboration has not happened yet and this
-- carries what it needs: the caller forces it only once it knows a phase will
-- run, which is what keeps a `--filter` typo from paying for a whole-graph
-- elaboration.
--
-- Forcing is the ONLY thing the filter may influence.  Which constructor this is
-- depends on doctest PRESENCE — measured on the module's unfiltered examples,
-- never on the filtered synth decls — because the constructor selects the
-- gate's driver, and a `--filter` that matched none would otherwise move a
-- doctest-bearing module to the other driver's gate.
data Prepared =
  | PreparedPair TestPair
  | PreparedInject (List (String, String, List Decl)) (List Decl)

-- Load + elaborate, once, for an import-bearing target: the gate text (None when
-- the module type-checks, or is exempt) beside the trees the three phases share.
--
-- THE GATE MUST NOT READ THE DOCTEST-INJECTED TREE.  A doctest EXPRESSION is not
-- required to type-check as a pure top-level binding — `stdlib/async.mdk`'s
-- `runAsync (sleep …)` examples perform `<Clock>`, so the synthesized
-- `__dt_i__ = debug (…)` bindings are an effectful value where `<>` is allowed —
-- and a module's doctests are not part of what `medaka check` accepts.  Reading
-- the injected tree would therefore reject modules `check` accepts.
--
-- So the gate's source depends on whether the module has doctests:
--
--   no doctests   the tree the phases need IS the graph as written, so one
--                 elaboration is both the gate and their input, and the gate is
--                 that elaboration's own per-module diagnostics (element 3 of
--                 `elaborateModules`' tuple) through `projectDiagsFromTc`.
--   doctests      the phases need the injected tree and the gate must not read
--                 it, so the two cannot be one pass, and the gate is the check
--                 driver over the graph already loaded (`projectDiagsLoaded`,
--                 keyed into the prelude and module-chain memos `check` mints).
--
-- The two drivers must agree on the IMPL UNIVERSE, or which arm a module
-- takes decides whether it type-checks — and adding a doctest would move it
-- between them.  `graphModuleWorker` passes `accAll ++ prog`
-- on both output selections (types/typecheck.mdk), so the two arms cannot diverge
-- on it.  `hasDoctests` is the module's UNFILTERED
-- doctest presence: the arm is chosen by what the module contains, so `--filter`
-- cannot move it.
prepareMulti : String ->
  String ->
  String ->
  List String ->
  Bool ->
  Bool ->
  List Decl ->
  <IO> (Option String, Prepared)
prepareMulti rsrc csrc target roots exempt hasDoctests synthDecls =
  match loadProgramFilesLocatedE (_ => None) target roots
    Err le => (
      loadGate exempt target le,
      PreparedPair (TestPairErr (loadErrorMessage le)),
    )
    Ok mods =>
      modulePathMap := map modIdToPath mods
      elaborateFor rsrc csrc target roots mods exempt hasDoctests synthDecls

elaborateFor : String ->
  String ->
  String ->
  List String ->
  List (String, String, List Decl) ->
  Bool ->
  Bool ->
  List Decl ->
  <IO> (Option String, Prepared)
elaborateFor rsrc csrc _target _roots mods exempt False _ =
  let runtimeDecls = desugaredPrelude rsrc
  let coreDecls = desugaredPrelude csrc
  let rawModules = desugaredModPairs mods
  match elaborateModules runtimeDecls coreDecls rawModules
    (coreE, modulesE, perModule, _, _, _) => (
      gateOfPerModule exempt runtimeDecls coreDecls mods perModule,
      PreparedPair
        (uncurryPair
          runtimeDecls
          coreDecls
          rawModules
          (mangleCtorCollisionsPair (coreE, modulesE))),
    )
elaborateFor rsrc csrc target roots mods exempt True synthDecls = (
  gateOfCheck exempt rsrc csrc target roots mods,
  PreparedInject mods synthDecls,
)

-- Build the phases' trees.  The injected elaboration runs AFTER the gate, so it
-- is still the last writer of the typechecker's whole-graph state — the position
-- a phase elaboration has always held.
forcePrepared : String -> String -> Prepared -> <IO> TestPair
forcePrepared _ _ (PreparedPair pair) = pair
forcePrepared rsrc csrc (PreparedInject mods synthDecls) =
  let injected = injectIntoLast synthDecls (desugaredModPairs mods)
  match (elaborateModules
    (desugaredPrelude rsrc)
    (desugaredPrelude csrc)
    injected)
    (coreE, modulesE, _, _, _, _) =>
      uncurryPair
        (desugaredPrelude rsrc)
        (desugaredPrelude csrc)
        injected
        (mangleCtorCollisionsPair (coreE, modulesE))

-- The doctest-bearing gate: `analyzeProject`'s verdict over the graph this
-- invocation already loaded, keyed into the same prelude and module-chain memos
-- `medaka check` mints, so nothing here re-parses or re-loads.
gateOfCheck : Bool ->
  String ->
  String ->
  String ->
  List String ->
  List (String, String, List Decl) ->
  <IO> Option String
gateOfCheck True _ _ _ _ _ = None
gateOfCheck False rsrc csrc target roots mods =
  renderGate
    (projectDiagsLoaded
      noStdlibExports
      True
      []
      (desugaredPrelude rsrc)
      (desugaredPrelude csrc)
      (Some (desugaredPreludeKey rsrc, desugaredPreludeKey csrc))
      (chainKeyOf target roots)
      mods)

uncurryPair : List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (List Decl, List (String, List Decl)) ->
  TestPair
uncurryPair runtimeDecls rawCore rawModules (core, mods) =
  TestPair runtimeDecls rawCore core rawModules mods

-- The single-file prop/`test "…"` arm's elaboration: the degenerate 1-module
-- list over the shadow-dropped prelude (`programIsCore` ⇒ [], so `medaka test
-- stdlib/core.mdk` does not double-prepend it).  Built once and shared by the
-- two phases, rather than elaborated once in each.
prepareSingle : List Decl ->
  List Decl ->
  String ->
  List String ->
  List Decl ->
  <IO> TestPair
prepareSingle runtimeDecls coreDecls target roots userDecls =
  let livePrelude =
    if programIsCore userDecls then
      []
    else
      dropShadowedExp (funNamesOf userDecls) coreDecls
  let rootId = singleRootId roots target
  modulePathMap := [(rootId, target)]
  uncurryPair
    runtimeDecls
    livePrelude
    [(rootId, userDecls)]
    (elaborateModulesMangled runtimeDecls livePrelude [(rootId, userDecls)])

driveAll : List Engine ->
  List Decl ->
  List Decl ->
  String ->
  String ->
  String ->
  String ->
  List String ->
  Int ->
  Option String ->
  List Decl ->
  Bool ->
  String ->
  PinIndex ->
  <IO> Bool
driveAll engines runtimeDecls coreDecls rsrc csrc target tsrc roots cases filterOpt userDecls exempt file index
  | hasUseDecls userDecls =
    driveMulti
      engines
      runtimeDecls
      rsrc
      csrc
      target
      tsrc
      roots
      cases
      filterOpt
      userDecls
      exempt
      file
      index
  | otherwise =
    match if exempt then None else singleFileTypeErrors target tsrc rsrc csrc
      Some errText =>
        let _ = ePutStrLn (typecheckGateFail target errText)
        False
      None =>
        driveSingle
          engines
          runtimeDecls
          coreDecls
          target
          tsrc
          roots
          cases
          filterOpt
          userDecls
          file
          index

driveMulti : List Engine ->
  List Decl ->
  String ->
  String ->
  String ->
  String ->
  List String ->
  Int ->
  Option String ->
  List Decl ->
  Bool ->
  String ->
  PinIndex ->
  <IO> Bool
driveMulti engines runtimeDecls rsrc csrc target tsrc roots cases filterOpt userDecls exempt file index =
  currentEvalFile := target
  let allExamples = extractExamples (collectComments tsrc)
  let examples = filterExamplesByName filterOpt allExamples
  let synthResults = buildSynthResults userDecls examples
  let synthDecls = buildSynthDecls synthResults
  let gated =
    prepareMulti
      rsrc
      csrc
      target
      roots
      exempt
      (isNonEmptyL allExamples)
      synthDecls
  match gated
    (Some errText, _) =>
      let _ = ePutStrLn (typecheckGateFail target errText)
      False
    (None, prepared) =>
      if filterMatchedNothing filterOpt tsrc userDecls then
        let _ = filterMatchedNothingNotice target
        False
      else
        let pair = forcePrepared rsrc csrc prepared
        let doctestsOk =
          runDoctests
            engines
            (DtPair pair)
            target
            tsrc
            userDecls
            examples
            synthResults
        let propsOk =
          runPropsPinned
            engines
            pair
            target
            tsrc
            userDecls
            cases
            filterOpt
            file
            index
        let testsOk =
          runTestDeclsPinned
            engines
            pair
            runtimeDecls
            target
            tsrc
            userDecls
            filterOpt
            file
            index
        doctestsOk && propsOk && testsOk

-- The prelude-only arm.  Its doctest phase evaluates a flat `elaborateOne` tree
-- and its prop/`test "…"` phases a pair, so the two cannot share one
-- elaboration; the two PHASES that can share one now do, and neither
-- elaboration happens for a module that declares nothing for it to run.
driveSingle : List Engine ->
  List Decl ->
  List Decl ->
  String ->
  String ->
  List String ->
  Int ->
  Option String ->
  List Decl ->
  String ->
  PinIndex ->
  <IO> Bool
driveSingle engines runtimeDecls coreDecls target tsrc roots cases filterOpt userDecls file index =
  currentEvalFile := target
  let examples =
    filterExamplesByName filterOpt (extractExamples (collectComments tsrc))
  if filterMatchedNothing filterOpt tsrc userDecls then
    let _ = filterMatchedNothingNotice target
    False
  else
    let doctestsOk =
      runDoctests
        engines
        (DtSingle runtimeDecls coreDecls target roots userDecls)
        target
        tsrc
        userDecls
        examples
        (buildSynthResults userDecls examples)
    if hasProps userDecls || hasTests userDecls then
      let pair = prepareSingle runtimeDecls coreDecls target roots userDecls
      let propsOk =
        runPropsPinned
          engines
          pair
          target
          tsrc
          userDecls
          cases
          filterOpt
          file
          index
      let testsOk =
        runTestDeclsPinned
          engines
          pair
          runtimeDecls
          target
          tsrc
          userDecls
          filterOpt
          file
          index
      doctestsOk && propsOk && testsOk
    else
      doctestsOk

filterMatchedNothingNotice : String -> <IO> Unit
filterMatchedNothingNotice target =
  ePutStrLn
    "medaka test: \{target}: --filter matched no doctests, props, or `test \"…\"` decls"

-- ── doctest phase ────────────────────────────────────────────────────────────

-- `medaka test --filter <substring>` (#2295) keeps only examples whose input
-- expression contains the substring — doctests have no separate "name", the
-- input line IS the identity a reader would filter by.
filterExamplesByName : Option String -> List Example -> List Example
filterExamplesByName None examples = examples
filterExamplesByName (Some sub) examples =
  filterList (ex => substringMatch sub (exampleInput ex)) examples

runDoctests : List Engine ->
  DoctestTrees ->
  String ->
  String ->
  List Decl ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> Bool
runDoctests engines trees target tsrc userDecls examples synthResults =
  let _ = putStrLn ("running doctests in " ++ target)
  match examples
    [] =>
      let _ = putStrLn "  (no doctests found)"
      True
    _ => runEngines engines trees target tsrc userDecls examples synthResults

-- Run the doctests under each requested engine in turn, AND-ing pass/fail
-- across engines. With exactly one engine (the default `[EngNative]`, or
-- `--engines eval`) no engine tag is printed and only ONE build/run happens.
-- With more than one, each engine's block is labelled so the reports (and
-- their independent pass/fail) don't run together.
runEngines : List Engine ->
  DoctestTrees ->
  String ->
  String ->
  List Decl ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> Bool
runEngines [e] trees target tsrc userDecls examples synthResults =
  reportDoctests
    target
    (runChosenOn e trees target tsrc userDecls examples synthResults)
runEngines engines trees target tsrc userDecls examples synthResults =
  runEnginesTagged engines trees target tsrc userDecls examples synthResults

runEnginesTagged : List Engine ->
  DoctestTrees ->
  String ->
  String ->
  List Decl ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> Bool
runEnginesTagged [] _ _ _ _ _ _ = True
runEnginesTagged (e :: rest) trees target tsrc userDecls examples synthResults =
  let _ = putStrLn ""
  let _ = putStrLn "-- \{engineName e} --"
  let ok =
    reportDoctests
      target
      (runChosenOn e trees target tsrc userDecls examples synthResults)
  let restOk =
    runEnginesTagged rest trees target tsrc userDecls examples synthResults
  ok && restOk

-- ── engine dispatch (#81 Stage 3) ────────────────────────────────────────────
-- The SINGLE call site that picks an execution engine. `EngInterp` runs
-- `runChosen` (today's interpreter path, verbatim); `EngNative` compiles the
-- module to a real native binary via `tools.native_doctest` (Stage 2) and runs
-- that. Both arms judge through the SAME `buildDetailsFrom` seam (one inside
-- `runChosen`, the other inside `runNativeDoctests` itself) — extraction, synth
-- generation, and judging are never duplicated here, only the execution engine
-- differs.
export
runChosenOn : Engine ->
  DoctestTrees ->
  String ->
  String ->
  List Decl ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> RunResult
runChosenOn EngInterp trees _target _tsrc _userDecls examples synthResults =
  runChosen trees examples synthResults
runChosenOn EngNative _trees target tsrc userDecls examples synthResults =
  runNativeDoctests target tsrc userDecls examples synthResults

-- The interpreter arm.  `DtPair` is the one elaboration the whole invocation
-- shares; `DtSingle` elaborates HERE — this is the first point that knows the
-- module has examples worth a tree.
--
-- The prelude-only shape drops the shadowed prelude, appends the synth decls,
-- dict-elaborates and runs.  When the file under test IS the prelude (`medaka
-- test stdlib/core.mdk`) it already declares everything the prelude provides,
-- so prepending it would duplicate every top-level decl (two `Bounded Char`
-- impls, etc.) and corrupt return-position dispatch — hence `programIsCore`.
-- `elaborateOne` is the 1-module wrapper over `elaborateModules` returning the
-- FLAT shape `evalOneRootEnvWith` consumes, and its root frame carries the
-- synthesized `__dt_i__` bindings the same way the pair arm's does.
runChosen : DoctestTrees ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> RunResult
runChosen (DtPair (TestPairErr e)) examples synthResults =
  buildDetailsFrom (Err e) synthResults examples
runChosen (DtPair (TestPair _runtimeM _rawCoreM coreM _rawM modsM)) examples synthResults =
  -- Root-FULL env (locals ∪ imports ∪ globals), not `evalModulesWith`'s
  -- locals-only `rootLocals`: `firstUnresolvedDottedRef` below needs the
  -- import frame visible to find (or fail to find) an alias-qualified name
  -- like `H.foo`, which `rootLocals` never carries (#3206). A `__dt_i__`
  -- synth binding is always in `localCells`, first in this flattened list
  -- either way, so this changes nothing about what `force` below returns.
  let env = evalModulesRootEnvWith (testCapableExterns ()) coreM modsM
  buildDetailsFrom
    (Ok (renderExamples env synthResults examples))
    synthResults
    examples
runChosen (DtSingle runtimeDecls coreDecls target roots userDecls) examples synthResults =
  let allUser = userDecls ++ buildSynthDecls synthResults
  let livePrelude =
    if programIsCore userDecls then
      []
    else
      dropShadowedExp (funNamesOf allUser) coreDecls
  let rootId = singleRootId roots target
  modulePathMap := [("__main__", target)]
  let elaborated = elaborateOne runtimeDecls livePrelude (rootId, allUser)
  let env =
    evalOneRootEnvWith (testCapableExterns ()) [] ("__main__", elaborated)
  buildDetailsFrom
    (Ok (renderExamples env synthResults examples))
    synthResults
    examples

-- ── The interpreter's adapter onto doctest.mdk's buildDetailsFrom seam ──────
-- buildDetailsFrom (Stage 1) wants "one rendered actual per example, or one
-- whole-file error" — not a raw interpreter env. This is the thin adapter:
-- for each example i, look up its synthesized `__dt_i__` binding in the post-
-- run env and render it, exactly as the pre-Stage-1 `oneResult` did inline.
renderExamples : List (String, Value e) ->
  List (Result String (List Decl)) ->
  List Example ->
  <e> List (Result String String)
renderExamples env synthResults examples =
  renderExamplesGo env synthResults 0 examples

renderExamplesGo : List (String, Value e) ->
  List (Result String (List Decl)) ->
  Int ->
  List Example ->
  <e> List (Result String String)
renderExamplesGo _ _ _ [] = []
renderExamplesGo env (sr :: srRest) i (ex :: rest) =
  renderOneExample env sr i ex :: renderExamplesGo env srRest (i + 1) rest
renderExamplesGo env [] i (ex :: rest) =
  renderOneExample env (Err "") i ex :: renderExamplesGo env [] (i + 1) rest

-- No binding for __dt_i__ means that example's synth never ran (its own
-- decl was dropped, or the file errored before reaching it) — reported the
-- same way the interpreter always has: "could not evaluate: <expr>".
--
-- #3206: an alias-qualified example (`H.foo 1`) whose target doesn't resolve
-- (a typo'd member, a stale alias) would otherwise reach `force`, which
-- PANICS on an unbound identifier — and a panic here is not catchable
-- (AGENTS.md), so it takes down every OTHER doctest in the file, not just
-- this one. A dotted name is unambiguously a qualified reference (a surface
-- identifier can never contain '.'), so checking each one `declRefs` finds in
-- this example against `env` — BEFORE forcing — catches exactly that failure
-- as a normal per-example `Errored`, the same shape #55 already uses for a
-- synth decl that failed to parse.
renderOneExample : List (String, Value e) ->
  Result String (List Decl) ->
  Int ->
  Example ->
  <e> Result String String
renderOneExample env sr i ex = match lookupBinding (synthName i) env
  None => Err ("could not evaluate: " ++ exampleInput ex)
  Some v => match firstUnresolvedDottedRef env sr
    Some name =>
      Err "could not evaluate: \{exampleInput ex} (unresolved: \{name})"
    None => Ok (ppValue (force v))

firstUnresolvedDottedRef : List (String, Value e) ->
  Result String (List Decl) ->
  Option String
firstUnresolvedDottedRef _ (Err _) = None
firstUnresolvedDottedRef env (Ok ds) =
  firstUnresolvedName env (flatMap declRefs ds)

firstUnresolvedName : List (String, Value e) -> List String -> Option String
firstUnresolvedName _ [] = None
firstUnresolvedName env (n :: rest)
  | isDottedRef n && isNone (lookupBinding n env) = Some n
  | otherwise = firstUnresolvedName env rest

-- A dot cannot occur in a surface identifier (desugar.mdk's alias rewrite
-- relies on the same fact) — a dotted name here is always a cross-module or
-- alias-qualified reference, never a locally bound one.
isDottedRef : String -> Bool
isDottedRef n = isSome (stringIndexOf "." n)

-- ARCH E-5 (#1521/#1223): the loader-derived id for a single-file test target —
-- shared by the prelude-only doctest arm and `prepareSingle`.  `deps` mirrors
-- `loadProgramFilesE`'s own `readDeps (findProjectRootOrSelf (parentDir entry))`
-- (`dirOf` here is that same "parent directory of the target" computation, just
-- imported from `support.path` rather than loader's private copy).
--
-- EXPORTED (#1526 blocker-2 follow-up): the retired origin-agreement probe's
-- single arm imported and called this DIRECTLY, rather than reimplementing the id
-- derivation independently — a prior version recomputed it inline, which meant
-- the gate could drift out of sync with this function silently (a change here
-- with no matching probe update would go undetected). Calling this export means
-- the gate now tracks whatever this function does, mechanically, by construction.
export
singleRootId : List String -> String -> <IO> String
singleRootId roots target =
  let deps = readDeps (findProjectRootOrSelf (dirOf target))
  canonicalPathId deps roots target

-- DRIVER-COLLAPSE Phase 1+3 note on the dict-set: the old `coreDictNames`
-- externally-built dict-set (preludeReturnPosDictNames ++ constrainedSigNames, with
-- arg-position helpers excluded to keep the `neq`-hang closed) is gone — the
-- single-file arms route through elaborateModules, which OWNS the
-- equivalent return-position dict-set via its own `moduleDictNames`.  The
-- `medaka test stdlib/core.mdk` canary guards the neq-hang.

-- Mirror of compiler/frontend/resolve.mdk's
-- programIsCore: the prelude is the unique program declaring BOTH the
-- `Ordering` data type and the `Foldable` interface.
programIsCore : List Decl -> Bool
programIsCore prog = pcHasOrdering prog && pcHasFoldable prog

pcHasOrdering : List Decl -> Bool
pcHasOrdering [] = False
pcHasOrdering ((DData { dataName = "Ordering" }) :: _) = True
pcHasOrdering (_ :: rest) = pcHasOrdering rest

pcHasFoldable : List Decl -> Bool
pcHasFoldable [] = False
pcHasFoldable ((DInterface { name = "Foldable", ... }) :: _) = True
pcHasFoldable (_ :: rest) = pcHasFoldable rest

-- Append synth decls to the ROOT (last) module in the loaded list.  The
-- loader returns modules in dependency-first order, so the entry (target)
-- is always last.  Using the last module avoids having to recompute the
-- module id from the target path + roots (which is how the loader keyed it),
-- making the injection robust to both relative and absolute target paths and
-- to nested module ids like "lib.probe" vs bare ids like "probe".
--
-- This is the SAME hazard `singleRootId`/`canonicalPathId` (ARCH E-5, above)
-- exists to close, not a contradiction of it.  This function
-- sidesteps recomputation entirely (position, not a recomputed id) because it
-- must MATCH an id the loader ALREADY minted for the multi-module entry
-- (`loadProgramFilesE`'s own `moduleIdOfPath roots entry`, first-root — a
-- recompute via `canonicalModId`'s last-root convention would NOT match it, and
-- a mismatch here means injecting into the wrong module or none).  The
-- single-file arm's `rootId` has no existing id to match — it MINTS the single node's only id — so
-- recomputing it via the loader's own dependency-resolution convention
-- (`canonicalPathId`) is what makes it agree with how a SIBLING target's graph
-- load would independently canonicalize this same file, which is the actual
-- #1223 property. Different problem, different function, not a disagreement.
injectIntoLast : List Decl ->
  List (String, List Decl) ->
  List (String, List Decl)
injectIntoLast _ [] = []
injectIntoLast synthDecls [(mid, decls)] = [(mid, decls ++ synthDecls)]
injectIntoLast synthDecls (x :: rest) = x :: injectIntoLast synthDecls rest

-- ── doctest reporting ─────────────────────────────────────────────────────

-- The per-example lines and the `(F failed, E errors)` suffix live in
-- `compiler/tools/doctest.mdk` (#81 Stage 2), beside `RunResult`: a native engine must
-- report a `RunResult` identically to this one, and three copies of the printer
-- is how that silently stops being true.
reportDoctests : String -> RunResult -> <IO> Bool
reportDoctests target result =
  let _ = printDoctestDetails target (runDetails result)
  let total = runPassed result + runFailed result + runErrors result
  let _ =
    putStr
      "\n\{target}: \{intToString (runPassed result)}/\{intToString total} passed"
  let _ = putStr (doctestFailSuffix result)
  let _ = putStr "\n"
  runFailed result == 0 && runErrors result == 0

-- ── prop phase ───────────────────────────────────────────────────────────────
-- Only runs (and prints) if the file declares props — mirrors the OCaml short
-- circuit (`Prop_runner.run_all` returns true with no output when none).

-- #2293/#2295 (a): raw-parse line lookup for `prop "…"` decls — same
-- rationale as `testLineTests` below (the elaborated body loses its ELoc, so
-- recover each prop's line from a POSITION-preserving reparse). Matched by
-- name (not position, unlike (b)'s `test "…"` fix): props are scoped to a name
-- match, not to (b)'s duplicate-name repair — a duplicate prop name is not
-- this slice's problem.
propLineTests : String -> List (String, Int)
propLineTests tsrc = collectPropLines (desugar (parseLocated tsrc))

collectPropLines : List Decl -> List (String, Int)
collectPropLines [] = []
collectPropLines ((DProp _ name _ body) :: rest) =
  (name, exprLine body) :: collectPropLines rest
collectPropLines (_ :: rest) = collectPropLines rest

-- ── #1292: elaborate, then rename cross-unit-colliding constructors ──────────
-- `eval.evalModulesRootEnvWith` / `evalModulesWith` apply this rename themselves,
-- but applying it only there is not enough for `medaka test`: the `test "…"` and
-- prop phases pull their BODIES out of the SAME elaborated module list they hand
-- the driver (`elaboratedRootProps`, `collectTests`) and evaluate them in the
-- driver's env.  A body left with bare constructor references would look for a
-- cell the rename has moved.  Applying it here renames env and bodies together;
-- the driver's own call is then an idempotent no-op.
elaborateModulesMangled : List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (List Decl, List (String, List Decl))
elaborateModulesMangled runtimeDecls coreDecls modules =
  match elaborateModules runtimeDecls coreDecls modules
    (coreE, modulesE, _, _, _, _) => mangleCtorCollisionsPair (coreE, modulesE)

-- Evaluate the file's `prop "…"` decls in the shared elaboration's root
-- environment.  `evalModulesRootEnv` exposes the prelude globals (eq/compare)
-- the prop bodies need, and the bodies themselves come from the ELABORATED root
-- module (dict-passed call sites) so the file's own `=>`-constrained fns (set's
-- `fromList`/`wellFormed`) get their leading dict argument — raw bodies would
-- under-apply the now-dict-passed call and `force` a partial closure, so every
-- prop would "fail".
runPropsPinned : List Engine ->
  TestPair ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  String ->
  PinIndex ->
  <IO> Bool
runPropsPinned engines pair target tsrc userDecls cases filterOpt file index
  | not (hasProps userDecls) = True
  | otherwise = match pair
    TestPairErr err =>
      let _ = ePutStrLn err
      False
    TestPair runtimeM rawCoreM coreM rawM modsM => withEvidencePreserved (_ =>
      printGradedPropRows
        (gradeProps
          index
          file
          (propsReportEngines
            engines
            runtimeM
            rawCoreM
            coreM
            rawM
            modsM
            target
            tsrc
            userDecls
            cases
            filterOpt
            file
            index)))

printGradedPropRows : List GradedProp -> <IO> Bool
printGradedPropRows [] = True
printGradedPropRows (row :: rest) =
  let raw = gradedPropRaw row
  let rawDetail = match gradedPropPinDetail row
    Some pin => "\{propResultDetail raw}; \{pin}"
    None => propResultDetail raw
  let detail =
    if propResultPassed raw && rawDetail == "" then
      "\{intToString (propResultCases raw)} tests passed"
    else
      rawDetail
  let _ =
    putStrLn
      "Testing \"\{propResultName raw}\" [\{propResultEngine raw}] ... \{if gradedPropPassed row then "OK" else "FAILED"} (\{detail})"
  let restPassed = printGradedPropRows rest
  gradedPropPassed row && restPassed

-- The root module's elaborated decls — the prop and `test "…"` bodies both come
-- from here.  The root module is the LAST in the list (the loader returns
-- modules dependency-first, so the entry is last), and the degenerate 1-module
-- single-file list is its own root.  Falls back to the raw `userDecls` for an
-- empty list, which no caller produces.
elaboratedRootProps : List (String, List Decl) -> List Decl -> List Decl
elaboratedRootProps modules userDecls = match lastModule modules
  Some decls => decls
  None => userDecls

lastModule : List (String, List Decl) -> Option (List Decl)
lastModule [] = None
lastModule [(_, decls)] = Some decls
lastModule (_ :: rest) = lastModule rest

-- ── test phase (Phase 127 restored 2026-07-11) ───────────────────────────────
-- Symmetric with the prop phase: only runs (and prints) if the file declares
-- `test "…"` decls.  Each body is evaluated to an `Expectation` VALUE (panics are
-- NOT caught — a genuinely-crashing body aborts the run), and the pass/fail is
-- reported with the SAME shape as the doctest phase (RunResult/ExResult + loc +
-- summary + exit code), per P0-6.  Discovery reads the same shared elaboration
-- the prop phase does, and — like it — pulls the DTest bodies from the
-- ELABORATED root module so their `expectEqual`/… call sites carry the dict
-- argument (`import test`'s constrained assertions).

-- `engines` selects the execution engine(s) the same way the doctest phase's
-- does, and each engine's block is labelled when there is more than one.
runTestDeclsPinned : List Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  String ->
  PinIndex ->
  <IO> Bool
runTestDeclsPinned engines pair runtimeDecls target tsrc userDecls filterOpt file index
  | not (hasTests userDecls) = True
  | otherwise =
    printGradedTestRows
      target
      (gradeTests
        index
        file
        (testRowsForPins
          (testDeclsReportPinned
            engines
            pair
            runtimeDecls
            target
            tsrc
            userDecls
            filterOpt
            file
            index)))

printGradedTestRows : String -> List GradedTest -> <IO> Bool
printGradedTestRows _ [] = True
printGradedTestRows target (row :: rest) =
  let (engine, name, line, raw) = gradedTestRaw row
  let label = "\{name} [\{engine}]"
  let _ = printTestRunning target line label
  let _ =
    if gradedTestStatus row == "known-red" then
      putStrLn
        "  known-red \{target}:\{intToString line}: \{label} (\{gradedTestPinDetailText row})"
    else
      printTestVerdict target line label raw
  let restPassed = printGradedTestRows target rest
  gradedTestPassed row && restPassed

gradedTestPinDetailText : GradedTest -> String
gradedTestPinDetailText row = match gradedTestPinDetail row
  Some detail => detail
  None => ""

testRowsForPins : List (Engine, String, Int, ExResult) ->
  List (String, String, Int, ExResult)
testRowsForPins [] = []
testRowsForPins ((engine, name, line, result) :: rest) =
  (engineName engine, name, line, result) :: testRowsForPins rest

-- The `test "…"` decls to evaluate: the elaborated root module's, with each
-- body's source line recovered from a position-preserving reparse.
rootTestsOf : Option String ->
  String ->
  List (String, List Decl) ->
  List Decl ->
  List (String, Int, Expr)
rootTestsOf filterOpt tsrc modsM userDecls =
  filterTestsByName
    filterOpt
    (attachRawLines
      (testLineTests tsrc)
      (collectTests (elaboratedRootProps modsM userDecls)))

-- ── the native arm ──────────────────────────────────────────────────────────
-- The probe compiles the file's SOURCE, so it needs the RAW (parsed, not
-- desugared, not elaborated) bodies: those are what `printer.declToString` can
-- render back as ordinary bindings for the probe program.  The interpreter arm
-- needs the opposite — the elaborated bodies, whose `expectEqual` call sites
-- already carry their dictionary argument.  Both lists come from the same
-- source through the same `--filter`, so index `i` names the same test in each.
nativeRawTests : String -> List (String, Int, Expr)
nativeRawTests tsrc = collectTests (parseLocated tsrc)

-- Line map keyed by test name, from a POSITION-populating reparse of the source
-- (the bare `parse` used elsewhere leaves placeholder line-1 locs).
testLineTests : String -> List (String, Int, Expr)
testLineTests tsrc = collectTests (desugar (parseLocated tsrc))

-- `medaka test --filter <substring>` (#2295): keep only `test "…"` decls whose
-- name contains the substring.
filterTestsByName : Option String ->
  List (String, Int, Expr) ->
  List (String, Int, Expr)
filterTestsByName None tests = tests
filterTestsByName (Some sub) tests =
  filterList (t => substringMatch sub (fst3 t)) tests

fst3 : (a, b, c) -> a
fst3 (a, _, _) = a

-- The elaborated (dict-passed) body loses its leading ELoc (the marker rewrites
-- the leftmost method EVar into a dict node), so take each test's line from the
-- RAW parsed decls.
--
-- #2295 (b): matched by POSITION, not by test NAME. A name match
-- collapses two same-named `test "…"` decls onto one line and reports line 0
-- for any name it fails to find (which can also happen silently on a
-- rename mismatch between the two decl lists). `raw` and the elaborated
-- `DTest` list both come from the SAME source (`testLineTests tsrc` and
-- `collectTests rootTests` respectively) via the same desugar pipeline that
-- neither reorders nor drops/duplicates DTest decls, so the Nth raw entry and
-- the Nth elaborated entry are the SAME source `test "…"` decl regardless of
-- what either is named — a position match survives duplicate names, and a raw
-- list at least as long as the elaborated one (the normal case) never falls
-- back to `0`.
attachRawLines : List (String, Int, Expr) ->
  List (String, Int, Expr) ->
  List (String, Int, Expr)
attachRawLines _ [] = []
attachRawLines [] ((name, _, body) :: rest) =
  (name, 0, body) :: attachRawLines [] rest
attachRawLines ((_, l, _) :: rawRest) ((name, _, body) :: rest) =
  (name, l, body) :: attachRawLines rawRest rest

-- ── the eval arm's capability gate (#2588) ──────────────────────────────────
-- `medaka test` evaluates `test "…"` bodies under a capability policy
-- (eval.testCapableExterns) that binds the clock, the GC counter and stderr and
-- nothing else.  A body reaching past it — directly, or through a stdlib
-- wrapper like `runCommandOk` — would otherwise die mid-run with eval's own `unbound
-- identifier runCommand`, a message about the interpreter's internals that
-- names no test and arrives after earlier tests have already reported.
--
-- The gate answers the same question by name, before anything runs, and refuses
-- the WHOLE FILE rather than the individual test: the tests that would still
-- have run are not the point when the file as written cannot be run as asked.
-- `--native` compiles a real binary and so has no such policy, which is what
-- the diagnostic points at.
uncapableExternsMsg : String -> List String -> String
uncapableExternsMsg target names =
  "\{target}: `test \"…\"` declarations here reach \{externWord names} \{joinCommas names}, which `medaka test` does not provide under the interpreter — its capability policy covers the clock, allocation counts and stderr only, so no filesystem, environment, stdin, network or subprocess extern is bound. No test was run. Run these tests natively instead: `medaka test --native \{target}`."

externWord : List String -> String
externWord [_] = "the extern"
externWord _ = "the externs"

joinCommas : List String -> String
joinCommas [] = ""
joinCommas [n] = "`\{n}`"
joinCommas (n :: rest) = "`\{n}`, " ++ joinCommas rest

-- Reuses the doctest reporting SHAPE (`ok`/`FAIL <f>:<line>: <name>`, then the
-- `<f>: P/T passed[ (F failed, E errors)]` summary + exit code, P0-6).  Like the
-- prop phase, each result is printed AS its body is evaluated (not batched), so a
-- body that aborts the run still leaves the tests that already passed on screen.
-- Returns True iff every test passed.
-- #2293: name the test BEFORE its outcome is known. Panics are uncatchable by
-- design (settled: isolation only, never catchability), so under the
-- interpreter this print is the runner's only chance to attribute a mid-run
-- process death — if the process dies inside `runOneTest`, this line is the
-- last thing on stdout, and the disappearance of every test after it is
-- explained rather than mysterious.
printTestRunning : String -> Int -> String -> <IO> Unit
printTestRunning target line name =
  putStrLn "  running \{target}:\{intToString line}: \{name}"

-- Prefixes every line of `msg` with the 7-space runner indent, not just the
-- first — a multi-line message (e.g. `expectNoFindings`'s `unlines`-joined
-- body) would otherwise read as outdented against the surrounding report.
indentVerdictMsg : String -> String
indentVerdictMsg msg = joinNl (map ("       " ++ _) (splitNl msg))

printTestVerdict : String -> Int -> String -> ExResult -> <IO> Unit
printTestVerdict target line name result =
  let loc = "\{target}:\{intToString line}"
  match result
    Pass _ _ => putStrLn "  ok   \{loc}: \{name}"
    Fail msg _ _ =>
      let _ = putStrLn "  FAIL \{loc}: \{name}"
      putStrLn (indentVerdictMsg msg)
    Errored msg =>
      let _ = putStrLn "  FAIL \{loc}: \{name}"
      putStrLn (indentVerdictMsg msg)

-- ── structured (non-printing) report — for `medaka mcp`'s medaka_test (#252) ──
-- Returns the doctest RunResult (per-example ExResult details) plus a PropResult
-- per property for `target`, WITHOUT printing anything: the human `medaka test`
-- path (runTest/driveAll above) is left entirely intact.  It reuses the SAME
-- drivers — `prepareMulti`/`prepareSingle` for the trees, `runChosen` for
-- doctests, `propsReport` for props — so
-- what medaka_test decides can never diverge from what `medaka test` would
-- decide, only how it is reported.  The prelude sources are parsed+desugared
-- here (mirroring runTest), and the module-search roots are derived exactly as
-- the CLI does (entry dir + project root, then stdlib).
--
-- #1443: gated by the SAME `typecheckExempt` predicate and the same two gates
-- `runTest` uses (`singleFileTypeErrors` prelude-only, `prepareMulti`'s
-- per-module verdict import-bearing), so a module that fails the type check can
-- no longer report a green (empty, `"ok":true`) summary here — the located
-- type-error text is returned as the first element instead, and no phase runs
-- (mirrors `runTest`, which never reaches a phase on a gate failure).  A
-- correctly EXEMPTED module (`test`/`prop`-bearing, no doctest) still runs
-- doctests+props normally with `None` here, just without the CLI's stderr
-- notice, since this path has no stderr channel of its own.
--
-- Results are under the engine(s) the caller asks for.  An interpreter-only run
-- cannot see a native-only miscompile (see #81), so a caller that asked for the
-- interpreter must present its results as "passes under eval", never as an
-- unqualified pass.
--
-- #2295 (d): the return tuple carries a 4th element, the `test "…"` phase's
-- structured results (`testDeclsReport`, above) — §4 of this slice's packet
-- licenses extending this shape (not reverting it) — plus a 5th, whether the
-- module was exempted from typechecking (`typecheckExempt`, F7: #1680/#1443's
-- skip marker would otherwise be human-arm-stderr-only, invisible to `--json`/MCP).
--
-- `cases`/`filterOpt` (F1) and `includeTestDecls` (F3) are per-caller: `medaka
-- mcp`'s `medaka_test` (#252/#1443) passes `(100, None, False)` — unchanged
-- counts/filtering (MCP has no --cases/--filter of its own) AND, as of F3,
-- the test-decl phase is no longer EVALUATED AT ALL on this path (previously
-- it always ran and only its result was discarded, so a panicking `test "…"`
-- decl could still kill the MCP server even though medaka_test never reports
-- test decls).  `medaka test --json` (the CLI, #2295) passes the user's own
-- `--cases`/`--filter` and `True`, so the JSON and human `medaka test` arms
-- agree on ALL THREE phases' counts for one target.
export
runTestReport : List Engine ->
  String ->
  String ->
  String ->
  String ->
  String ->
  Int ->
  Option String ->
  Bool ->
  <IO> (Option String, List (Engine, RunResult), List PropResult, List (Engine, String, Int, ExResult), Bool)
runTestReport engines runtimeSrc coreSrc target tsrc stdlibDir cases filterOpt includeTestDecls =
  runTestReportPinned
    engines
    runtimeSrc
    coreSrc
    target
    tsrc
    stdlibDir
    cases
    filterOpt
    includeTestDecls
    ""
    omEmpty

runTestReportPinned : List Engine ->
  String ->
  String ->
  String ->
  String ->
  String ->
  Int ->
  Option String ->
  Bool ->
  String ->
  PinIndex ->
  <IO> (Option String, List (Engine, RunResult), List PropResult, List (Engine, String, Int, ExResult), Bool)
runTestReportPinned engines runtimeSrc coreSrc target tsrc stdlibDir cases filterOpt includeTestDecls file index =
  -- S-1/#2234 (F-converge): content-keyed prelude memo (see `runTest` above).
  let runtimeDecls = desugaredPrelude runtimeSrc
  let coreDecls = desugaredPrelude coreSrc
  let roots = entrySearchRoots (dirOf target) ++ [stdlibDir]
  let userDecls = desugar (parse tsrc)
  let exempt = typecheckExempt target userDecls tsrc
  if hasUseDecls userDecls then
    reportMulti
      engines
      runtimeDecls
      runtimeSrc
      coreSrc
      target
      tsrc
      roots
      cases
      filterOpt
      includeTestDecls
      userDecls
      exempt
      file
      index
  else match (if exempt then
    None
  else
    singleFileTypeErrors target tsrc runtimeSrc coreSrc)
    Some errText => (Some errText, [], [], [], False)
    None =>
      reportSingle
        engines
        runtimeDecls
        coreDecls
        target
        tsrc
        roots
        cases
        filterOpt
        includeTestDecls
        userDecls
        exempt
        file
        index

-- The ledger is loaded exactly once for the selected target. Declaration names
-- are checked before any name filter applies, so a stale/ambiguous pin cannot
-- disappear behind `--filter`. The returned wrappers retain every raw result;
-- callers choose their status and summaries from the attached verdict only.
export
runTestGradedReport : List Engine ->
  String ->
  String ->
  String ->
  String ->
  String ->
  Int ->
  Option String ->
  Bool ->
  <IO> (Option String, List (Engine, RunResult), List GradedProp, List GradedTest, Bool)
runTestGradedReport engines runtimeSrc coreSrc target tsrc stdlibDir cases filterOpt includeTestDecls =
  do
    let userDecls = desugar (parse tsrc)
    match loadPinContext target
      Err err => (Some err, [], [], [], False)
      Ok context =>
        match (validatePinNames
          context.contextPins
          context.contextFile
          (propNamesOf userDecls)
          (testNamesOf userDecls))
          Err err => (Some err, [], [], [], False)
          Ok () => match buildPinIndex context.contextPins
            Err err => (Some err, [], [], [], False)
            Ok index =>
              let (reportError, runs, props, tests, skipped) =
                runTestReportPinned
                  engines
                  runtimeSrc
                  coreSrc
                  target
                  tsrc
                  stdlibDir
                  cases
                  filterOpt
                  includeTestDecls
                  context.contextFile
                  index
              (
                reportError,
                runs,
                gradeProps index context.contextFile props,
                gradeTests index context.contextFile (testRowsForPins tests),
                skipped,
              )

propNamesOf : List Decl -> List String
propNamesOf [] = []
propNamesOf ((DProp _ name _ _) :: rest) = name :: propNamesOf rest
propNamesOf (_ :: rest) = propNamesOf rest

testNamesOf : List Decl -> List String
testNamesOf [] = []
testNamesOf ((DTest _ name _) :: rest) = name :: testNamesOf rest
testNamesOf (_ :: rest) = testNamesOf rest

-- The import-bearing arm of `runTestReport`: the SAME one load + one
-- elaboration + one gate `medaka test`'s printing arm uses (`driveMulti`), so
-- MCP and the CLI can never disagree about a module.
reportMulti : List Engine ->
  List Decl ->
  String ->
  String ->
  String ->
  String ->
  List String ->
  Int ->
  Option String ->
  Bool ->
  List Decl ->
  Bool ->
  String ->
  PinIndex ->
  <IO> (Option String, List (Engine, RunResult), List PropResult, List (Engine, String, Int, ExResult), Bool)
reportMulti engines runtimeDecls rsrc csrc target tsrc roots cases filterOpt includeTestDecls userDecls exempt file index =
  let allExamples = extractExamples (collectComments tsrc)
  let examples = filterExamplesByName filterOpt allExamples
  let synthResults = buildSynthResults userDecls examples
  let prepared =
    prepareMulti
      rsrc
      csrc
      target
      roots
      exempt
      (isNonEmptyL allExamples)
      (buildSynthDecls synthResults)
  match prepared
    (Some errText, _) => (Some errText, [], [], [], False)
    (None, prepared) =>
      let pair = forcePrepared rsrc csrc prepared
      (
        None,
        doctestReport
          engines
          (DtPair pair)
          target
          tsrc
          userDecls
          examples
          synthResults,
        propsReportPinned
          engines
          pair
          target
          tsrc
          userDecls
          cases
          filterOpt
          file
          index,
        reportTestDecls
          includeTestDecls
          engines
          pair
          runtimeDecls
          target
          tsrc
          userDecls
          filterOpt
          file
          index,
        exempt,
      )

-- The prelude-only arm: the prop and `test "…"` phases share one elaboration,
-- and neither it nor the doctest arm's flat tree is built for a module that
-- declares nothing for it to run.
reportSingle : List Engine ->
  List Decl ->
  List Decl ->
  String ->
  String ->
  List String ->
  Int ->
  Option String ->
  Bool ->
  List Decl ->
  Bool ->
  String ->
  PinIndex ->
  <IO> (Option String, List (Engine, RunResult), List PropResult, List (Engine, String, Int, ExResult), Bool)
reportSingle engines runtimeDecls coreDecls target tsrc roots cases filterOpt includeTestDecls userDecls exempt file index =
  let examples =
    filterExamplesByName filterOpt (extractExamples (collectComments tsrc))
  let doctestRuns =
    doctestReport
      engines
      (DtSingle runtimeDecls coreDecls target roots userDecls)
      target
      tsrc
      userDecls
      examples
      (buildSynthResults userDecls examples)
  if hasProps userDecls || includeTestDecls && hasTests userDecls then
    let pair = prepareSingle runtimeDecls coreDecls target roots userDecls
    (
      None,
      doctestRuns,
      propsReportPinned
        engines
        pair
        target
        tsrc
        userDecls
        cases
        filterOpt
        file
        index,
      reportTestDecls
        includeTestDecls
        engines
        pair
        runtimeDecls
        target
        tsrc
        userDecls
        filterOpt
        file
        index,
      exempt,
    )
  else
    (None, doctestRuns, [], [], exempt)

-- `includeTestDecls` (F3) is per-caller: `medaka mcp`'s `medaka_test` passes
-- False, so the phase is not EVALUATED at all there — a panicking `test "…"`
-- decl cannot kill the MCP server through a result it never reports.
reportTestDecls : Bool ->
  List Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List (Engine, String, Int, ExResult)
reportTestDecls False _ _ _ _ _ _ _ _ _ = []
reportTestDecls True engines pair runtimeDecls target tsrc userDecls filterOpt file index =
  testDeclsReportPinned
    engines
    pair
    runtimeDecls
    target
    tsrc
    userDecls
    filterOpt
    file
    index

-- Doctest phase as pure data: extraction + runChosenOn per requested engine,
-- minus reportDoctests' printing.  A file with zero doctests yields the empty
-- RunResult for every engine.  Positionally tagged by engine so a caller
-- (e.g. `medaka mcp`'s medaka_test) can derive an "engine" label instead of
-- hardcoding one.  `filterOpt` mirrors `runDoctests`' `filterExamplesByName`
-- (F1: `medaka test --json --filter` was silently ignoring this) — MCP's
-- medaka_test still passes `None` (unchanged behavior, #2295 scoped to CLI).
doctestReport : List Engine ->
  DoctestTrees ->
  String ->
  String ->
  List Decl ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> List (Engine, RunResult)
doctestReport engines _trees _target _tsrc _userDecls [] _synthResults =
  emptyDoctestRuns engines
doctestReport engines trees target tsrc userDecls examples synthResults =
  doctestReportGo engines trees target tsrc userDecls examples synthResults

emptyDoctestRuns : List Engine -> List (Engine, RunResult)
emptyDoctestRuns [] = []
emptyDoctestRuns (e :: rest) =
  (e, RunResult 0 0 0 0 []) :: emptyDoctestRuns rest

doctestReportGo : List Engine ->
  DoctestTrees ->
  String ->
  String ->
  List Decl ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> List (Engine, RunResult)
doctestReportGo [] _ _ _ _ _ _ = []
doctestReportGo (e :: rest) trees target tsrc userDecls examples synthResults =
  (e, runChosenOn e trees target tsrc userDecls examples synthResults)
    :: doctestReportGo rest trees target tsrc userDecls examples synthResults

-- Prop phase as pure data: same single-file/multi-module split as the human
-- path, with raw engine outcomes graded only after both engines complete.
-- `cases`/`filterOpt` mirror `runProps`' own parameters (F1: `medaka test
-- --json --cases`/`--filter` were silently ignored) — MCP's medaka_test still
-- passes `(100, None)` (unchanged behavior, #2295 is scoped to the CLI).
-- The raw runner stays ledger-agnostic. A command report builds this index once
-- for its selected file, derives per-engine requests (including a pin's replay
-- seed/case count), then grades the raw rows separately.
propsReportPinned : List Engine ->
  TestPair ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List PropResult
propsReportPinned engines pair target tsrc userDecls cases filterOpt file index
  | not (hasProps userDecls) = []
  | otherwise = match pair
    TestPairErr _ => []
    TestPair runtimeM rawCoreM coreM rawM modsM => withEvidencePreserved (_ =>
      propsReportEngines
        engines
        runtimeM
        rawCoreM
        coreM
        rawM
        modsM
        target
        tsrc
        userDecls
        cases
        filterOpt
        file
        index)

propsReportEnginesInProcess : List Engine ->
  List Decl ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List (String, List Decl) ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List PropResult
propsReportEnginesInProcess [] _ _ _ _ _ _ _ _ _ _ _ _ = []
propsReportEnginesInProcess engines runtimeM rawCoreM coreM rawM modsM target tsrc userDecls cases filterOpt file index =
  let modules = planModules rawCoreM coreM rawM modsM
  let root = rootPlanModuleId rawM target
  let planningRequests =
    propRequestsFor index file "eval" userDecls cases filterOpt
  match (preparePlannedPropRequests
    root
    modules
    planningRequests
    (elaboratedRootProps modsM userDecls))
    Err _ =>
      propsReportEnginesPlain
        engines
        rawCoreM
        coreM
        rawM
        modsM
        target
        tsrc
        userDecls
        cases
        filterOpt
        file
        index
    Ok (planEnv, planningRows) =>
      let plans = preparedPlans planningRows
      match customPlansReachable planEnv plans
        [] =>
          propsReportEnginesPlain
            engines
            rawCoreM
            coreM
            rawM
            modsM
            target
            tsrc
            userDecls
            cases
            filterOpt
            file
            index
        _ =>
          let validation =
            validateHelperPlans planEnv runtimeM rawCoreM rawM plans
          runValidatedPropEngines
            engines
            validation
            target
            tsrc
            userDecls
            cases
            filterOpt
            file
            index

-- The parent keeps the native engine in-process, but isolates every interpreter
-- property batch. A language panic cannot cross this process boundary, so native
-- results still arrive after a panicking generator, shrinker, or property body.
propsReportEngines : List Engine ->
  List Decl ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List (String, List Decl) ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List PropResult
propsReportEngines [] _ _ _ _ _ _ _ _ _ _ _ _ = []
propsReportEngines (EngInterp :: rest) runtimeM rawCoreM coreM rawM modsM target tsrc userDecls cases filterOpt file index =
  superviseEvalProps
      target
      (propRequestsFor index file "eval" userDecls cases filterOpt)
    ++ propsReportEngines
      rest
      runtimeM
      rawCoreM
      coreM
      rawM
      modsM
      target
      tsrc
      userDecls
      cases
      filterOpt
      file
      index
propsReportEngines (EngNative :: rest) runtimeM rawCoreM coreM rawM modsM target tsrc userDecls cases filterOpt file index =
  propsReportEnginesInProcess
      [EngNative]
      runtimeM
      rawCoreM
      coreM
      rawM
      modsM
      target
      tsrc
      userDecls
      cases
      filterOpt
      file
      index
    ++ propsReportEngines
      rest
      runtimeM
      rawCoreM
      coreM
      rawM
      modsM
      target
      tsrc
      userDecls
      cases
      filterOpt
      file
      index

-- The evaluator child is deliberately one process per target, not per property:
-- refs and memoized globals remain shared between every selected law and case.
superviseEvalProps : String -> List PropRequest -> <IO> List PropResult
superviseEvalProps _ [] = []
superviseEvalProps target requests =
  let medaka = envOr "MEDAKA" (executablePath ())
  let argv = ["test", "--props-worker"] ++ workerPositionals target requests
  match runCommand medaka argv
    Err message =>
      workerRuntimeRows
        requests
        "could not start interpreter property worker: \{message}"
    Ok (code, stdout, stderr) => match takeEvalPropBootstrap stdout
      Err message =>
        if code == 0 then
          workerProtocolRows requests message
        else
          workerRuntimeRows requests (workerAbortDetail code stderr)
      Ok (nonce, transcript) =>
        match decodeEvalPropRows nonce requests transcript
          Ok rows =>
            if code == 0 then
              rows
            else
              workerRuntimeRows requests (workerAbortDetail code stderr)
          Err message =>
            if code == 0 then
              workerProtocolRows requests message
            else
              workerRuntimeRows requests (workerAbortDetail code stderr)

workerAbortDetail : Int -> String -> String
workerAbortDetail code stderr =
  let first = firstNonEmptyLine (splitNl stderr)
  "interpreter property worker batch aborted (exit \{intToString code})"
    ++ (if first == "" then "" else " — \{first}")

workerPositionals : String -> List PropRequest -> List String
workerPositionals target requests = target :: workerRequestPositionals requests

workerRequestPositionals : List PropRequest -> List String
workerRequestPositionals [] = []
workerRequestPositionals ((PropRequest name seed cases) :: rest) =
  stringify (JString name)
    :: stringify (JString (intToString seed))
    :: stringify (JString (intToString cases))
    :: workerRequestPositionals rest

workerRuntimeRows : List PropRequest -> String -> List PropResult
workerRuntimeRows [] _ = []
workerRuntimeRows ((PropRequest name seed cases) :: rest) message =
  PropResult
      "eval"
      name
      PropErroredResult
      (Some PropRuntimeError)
      message
      seed
      cases
    :: workerRuntimeRows rest message

workerProtocolRows : List PropRequest -> String -> List PropResult
workerProtocolRows [] _ = []
workerProtocolRows ((PropRequest name seed cases) :: rest) message =
  PropResult
      "eval"
      name
      PropErroredResult
      (Some PropProtocolError)
      message
      seed
      cases
    :: workerProtocolRows rest message

-- The internal worker reuses the normal loading, elaboration, helper injection,
-- and actual-root-environment paths. It deliberately runs no doctests or test
-- declarations: this child exists solely to contain property evaluation panics.
export
runEvalPropsWorker : String -> List PropRequest -> <IO> Unit
runEvalPropsWorker target requests =
  let nonce = startEvalPropWorker ()
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let runtimePath = joinPath root "stdlib/runtime.mdk"
  let corePath = joinPath root "stdlib/core.mdk"
  let stdlibDir = joinPath root "stdlib"
  match readPreludeFile runtimePath
    Err message => evalWorkerDie "could not read runtime prelude: \{message}"
    Ok runtimeSrc => match readPreludeFile corePath
      Err message => evalWorkerDie "could not read core prelude: \{message}"
      Ok coreSrc => match readSource target
        Err message =>
          evalWorkerDie "could not read property target: \{message}"
        Ok tsrc => match parseResult tsrc
          Err _ => evalWorkerDie "could not parse property target"
          Ok parsed =>
            runEvalPropsWorkerSource
              target
              nonce
              requests
              runtimeSrc
              coreSrc
              stdlibDir
              tsrc
              (desugar parsed)

evalWorkerDie : String -> <IO> Unit
evalWorkerDie message = do
  let _ = ePutStrLn "medaka test --props-worker: \{message}"
  exit 1

runEvalPropsWorkerSource : String ->
  String ->
  List PropRequest ->
  String ->
  String ->
  String ->
  String ->
  List Decl ->
  <IO> Unit
runEvalPropsWorkerSource target nonce requests runtimeSrc coreSrc stdlibDir tsrc userDecls =
  let runtimeDecls = desugaredPrelude runtimeSrc
  let coreDecls = desugaredPrelude coreSrc
  let roots = entrySearchRoots (dirOf target) ++ [stdlibDir]
  let exempt = typecheckExempt target userDecls tsrc
  currentEvalFile := target
  if hasUseDecls userDecls then
    let prepared = prepareMulti runtimeSrc coreSrc target roots exempt False []
    match prepared
      (Some message, _) => evalWorkerDie (typecheckGateFail target message)
      (None, work) =>
        let rows = withEvidencePreserved (_ =>
          runEvalRequestRows
            (forcePrepared runtimeSrc coreSrc work)
            target
            tsrc
            userDecls
            requests)
        emitEvalPropRows nonce rows
  else match (if exempt then
    None
  else
    singleFileTypeErrors target tsrc runtimeSrc coreSrc)
    Some message => evalWorkerDie (typecheckGateFail target message)
    None =>
      let rows = withEvidencePreserved (_ =>
        runEvalRequestRows
          (prepareSingle runtimeDecls coreDecls target roots userDecls)
          target
          tsrc
          userDecls
          requests)
      emitEvalPropRows nonce rows

runEvalRequestRows : TestPair ->
  String ->
  String ->
  List Decl ->
  List PropRequest ->
  <IO> List PropResult
runEvalRequestRows (TestPairErr message) _ _ _ requests =
  workerRuntimeRows
    requests
    "interpreter property worker could not prepare properties: \{message}"
runEvalRequestRows (TestPair runtimeM rawCoreM coreM rawM modsM) target tsrc userDecls requests =
  let root = rootPlanModuleId rawM target
  let modules = planModules rawCoreM coreM rawM modsM
  match (preparePlannedPropRequests
    root
    modules
    requests
    (elaboratedRootProps modsM userDecls))
    Err err => preparedResults (map (preparedPlanError "eval" err) requests)
    Ok (planEnv, rows) =>
      match customPlansReachable planEnv (preparedPlans rows)
        [] => runEvalPreparedRows planEnv [] rows tsrc coreM modsM
        _ =>
          runValidatedEvalRequests
            (validateHelperPlans
              planEnv
              runtimeM
              rawCoreM
              rawM
              (preparedPlans rows))
            target
            tsrc
            userDecls
            requests

runValidatedEvalRequests : HelperValidation ->
  String ->
  String ->
  List Decl ->
  List PropRequest ->
  <IO> List PropResult
runValidatedEvalRequests (HelperValidation pair helpers rejected protocol) target tsrc userDecls requests =
  match protocol
    Some message =>
      runEvalProtocolRequests pair message target tsrc userDecls requests
    None => match pair
      TestPairErr message =>
        workerRuntimeRows
          requests
          "interpreter property helpers could not prepare: \{message}"
      TestPair _runtimeM rawCoreM coreM rawM modsM =>
        let root = rootPlanModuleId rawM target
        let modules = planModules rawCoreM coreM rawM modsM
        match (preparePlannedPropRequests
          root
          modules
          requests
          (elaboratedRootProps modsM userDecls))
          Err err =>
            preparedResults (map (preparedPlanError "eval" err) requests)
          Ok (planEnv, rows) =>
            runEvalPreparedRows
              planEnv
              helpers
              (rejectPreparedHelpers planEnv "eval" rejected rows)
              tsrc
              coreM
              modsM

runEvalProtocolRequests : TestPair ->
  String ->
  String ->
  String ->
  List Decl ->
  List PropRequest ->
  <IO> List PropResult
runEvalProtocolRequests (TestPairErr message) _ _ _ _ requests =
  workerRuntimeRows
    requests
    "interpreter property helpers could not prepare: \{message}"
runEvalProtocolRequests (TestPair _runtimeM rawCoreM coreM rawM modsM) message target tsrc userDecls requests =
  let root = rootPlanModuleId rawM target
  let modules = planModules rawCoreM coreM rawM modsM
  match (preparePlannedPropRequests
    root
    modules
    requests
    (elaboratedRootProps modsM userDecls))
    Err err => preparedResults (map (preparedPlanError "eval" err) requests)
    Ok (planEnv, rows) =>
      runEvalPreparedRows
        planEnv
        []
        (rejectPreparedProtocolCustom planEnv "eval" message rows)
        tsrc
        coreM
        modsM

runEvalPreparedRows : PlanEnv ->
  List PropHelper ->
  List PreparedPropRequest ->
  String ->
  List Decl ->
  List (String, List Decl) ->
  <IO> List PropResult
runEvalPreparedRows env helpers rows tsrc coreM modsM =
  runPreparedPropRequestsResults
    env
    helpers
    rows
    (propLineTests tsrc)
    (evalModulesRootEvalEnvWith (testCapableExterns ()) coreM modsM)
    (coreM ++ flatMap snd modsM)

-- The structural-only path keeps the established engine behavior unchanged.
propsReportEnginesPlain : List Engine ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List (String, List Decl) ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List PropResult
propsReportEnginesPlain [] _ _ _ _ _ _ _ _ _ _ _ = []
propsReportEnginesPlain (EngInterp :: rest) rawCoreM coreM rawM modsM target tsrc userDecls cases filterOpt file index =
  runAllPlannedPropRequestsResults
      (rootPlanModuleId rawM target)
      (planModules rawCoreM coreM rawM modsM)
      (propRequestsFor index file "eval" userDecls cases filterOpt)
      (propLineTests tsrc)
      (evalModulesRootEvalEnvWith (testCapableExterns ()) coreM modsM)
      (elaboratedRootProps modsM userDecls)
    ++ propsReportEnginesPlain
      rest
      rawCoreM
      coreM
      rawM
      modsM
      target
      tsrc
      userDecls
      cases
      filterOpt
      file
      index
propsReportEnginesPlain (EngNative :: rest) rawCoreM coreM rawM modsM target tsrc userDecls cases filterOpt file index =
  runNativePlannedPropRequests
      target
      tsrc
      (planModules rawCoreM coreM rawM modsM)
      (propRequestsFor index file "native" userDecls cases filterOpt)
    ++ propsReportEnginesPlain
      rest
      rawCoreM
      coreM
      rawM
      modsM
      target
      tsrc
      userDecls
      cases
      filterOpt
      file
      index

preparedPlans : List PreparedPropRequest -> List GenPlan
preparedPlans rows = preparedPlansGo rows []

preparedPlansGo : List PreparedPropRequest -> List GenPlan -> List GenPlan
preparedPlansGo [] acc = reverseL acc
preparedPlansGo ((PreparedRun _ _ plans) :: rest) acc =
  preparedPlansGo rest (prependPlans plans acc)
preparedPlansGo (_ :: rest) acc = preparedPlansGo rest acc

prependPlans : List GenPlan -> List GenPlan -> List GenPlan
prependPlans [] acc = acc
prependPlans (plan :: rest) acc = prependPlans rest (plan :: acc)

-- Baseline diagnostics are keyed by their complete typecheck goal.  A helper
-- pass is allowed to add only diagnostics located in a synthetic helper body.
validateHelperPlans : PlanEnv ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List GenPlan ->
  HelperValidation
validateHelperPlans planEnv runtimeM rawCoreM rawM plans =
  let baseline = helperDiagIndex (helperElabDiags runtimeM rawCoreM rawM)
  validateHelperPlansGo planEnv runtimeM rawCoreM rawM plans baseline omEmpty

validateHelperPlansGo : PlanEnv ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List GenPlan ->
  OrdMap Unit ->
  OrdMap String ->
  HelperValidation
validateHelperPlansGo planEnv runtimeM rawCoreM rawM plans baseline rejected =
  let (PropHelpers helpers decls) = propHelpersForPlans planEnv plans
  match helpers
    [] =>
      HelperValidation (helperPair runtimeM rawCoreM rawM []) [] rejected None
    _ =>
      let candidate = helperPair runtimeM rawCoreM rawM decls
      let delta =
        helperDiagDelta
          baseline
          (helperElabDiagsWith runtimeM rawCoreM rawM decls)
      let helperFiles = helperFileIndex helpers 0 omEmpty
      let (bad, unexpected) = helperDiagFailures helperFiles delta omEmpty False
      if omKeys bad == [] then
        if unexpected then
          HelperValidation
            (helperPair runtimeM rawCoreM rawM [])
            []
            rejected
            (Some
              "property helper elaboration produced an unattributed diagnostic")
        else
          HelperValidation candidate helpers rejected None
      else
        let merged = mergeHelperFailures rejected bad
        let kept = filterHelperPlans planEnv merged plans
        validateHelperPlansGo
          planEnv
          runtimeM
          rawCoreM
          rawM
          kept
          baseline
          merged

helperPair : List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List Decl ->
  TestPair
helperPair runtimeM rawCoreM rawM decls =
  let injected = injectIntoLast decls rawM
  match elaborateModules runtimeM rawCoreM injected
    (coreE, modulesE, _, _, _, _) =>
      let (coreM, modsM) = mangleCtorCollisionsPair (coreE, modulesE)
      TestPair runtimeM rawCoreM coreM injected modsM

helperElabDiags : List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List (String, TcDiag)
helperElabDiags runtimeM rawCoreM rawM =
  helperElabDiagsWith runtimeM rawCoreM rawM []

helperElabDiagsWith : List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List Decl ->
  List (String, TcDiag)
helperElabDiagsWith runtimeM rawCoreM rawM decls =
  match elaborateModules runtimeM rawCoreM (injectIntoLast decls rawM)
    (_, _, perModule, residual, _, _) =>
      residual ++ perModuleErrors perModule []

perModuleErrors : List (String, (List TcDiag, List TcDiag)) ->
  List (String, TcDiag) ->
  List (String, TcDiag)
perModuleErrors [] acc = acc
perModuleErrors ((mid, (errors, _)) :: rest) acc =
  perModuleErrors rest (prependTcRows mid errors acc)

prependTcRows : String ->
  List TcDiag ->
  List (String, TcDiag) ->
  List (String, TcDiag)
prependTcRows _ [] acc = acc
prependTcRows mid (diag :: rest) acc =
  prependTcRows mid rest ((mid, diag) :: acc)

helperDiagIndex : List (String, TcDiag) -> OrdMap Unit
helperDiagIndex [] = omEmpty
helperDiagIndex (diag :: rest) =
  omInsert (tcDiagGoalKey diag) () (helperDiagIndex rest)

helperDiagDelta : OrdMap Unit -> List (String, TcDiag) -> List (String, TcDiag)
helperDiagDelta _ [] = []
helperDiagDelta baseline (diag :: rest)
  | omHasKey (tcDiagGoalKey diag) baseline = helperDiagDelta baseline rest
  | otherwise = diag :: helperDiagDelta baseline rest

helperFileIndex : List PropHelper -> Int -> OrdMap String -> OrdMap String
helperFileIndex [] _ acc = acc
helperFileIndex ((PropHelper word _ _) :: rest) i acc =
  helperFileIndex
    rest
    (i + 1)
    (omInsert "<property-helper:\{intToString i}>" word acc)

helperDiagFailures : OrdMap String ->
  List (String, TcDiag) ->
  OrdMap String ->
  Bool ->
  (OrdMap String, Bool)
helperDiagFailures _ [] bad unexpected = (bad, unexpected)
helperDiagFailures files ((_, TcDiag _ _ loc message _ _) :: rest) bad unexpected =
  match loc
    Some (Loc file _ _ _ _) => match omLookup file files
      Some word =>
        helperDiagFailures files rest (omInsert word message bad) unexpected
      None => helperDiagFailures files rest bad True
    None => helperDiagFailures files rest bad True

mergeHelperFailures : OrdMap String -> OrdMap String -> OrdMap String
mergeHelperFailures prior next = mergeHelperFailureKeys (omKeys next) prior next

mergeHelperFailureKeys : List String ->
  OrdMap String ->
  OrdMap String ->
  OrdMap String
mergeHelperFailureKeys [] acc _ = acc
mergeHelperFailureKeys (word :: rest) acc next = match omLookup word next
  None => mergeHelperFailureKeys rest acc next
  Some message => mergeHelperFailureKeys rest (omInsert word message acc) next

filterHelperPlans : PlanEnv -> OrdMap String -> List GenPlan -> List GenPlan
filterHelperPlans env rejected =
  filterList (planHasNoRejectedCarrier env rejected)

planHasNoRejectedCarrier : PlanEnv -> OrdMap String -> GenPlan -> Bool
planHasNoRejectedCarrier env rejected plan =
  not (anyList (customRejected rejected) (customPlansReachable env [plan]))

plansHaveNoRejectedCarrier : PlanEnv -> OrdMap String -> List GenPlan -> Bool
plansHaveNoRejectedCarrier env rejected plans =
  not (anyList (customRejected rejected) (customPlansReachable env plans))

customRejected : OrdMap String -> CustomPlan -> Bool
customRejected rejected (CustomPlan _ _ word) = omHasKey word rejected

runValidatedPropEngines : List Engine ->
  HelperValidation ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List PropResult
runValidatedPropEngines [] _ _ _ _ _ _ _ _ = []
runValidatedPropEngines engines (HelperValidation pair helpers rejected protocol) target tsrc userDecls cases filterOpt file index =
  match protocol
    Some message =>
      runProtocolHelperEngines
        engines
        pair
        message
        target
        tsrc
        userDecls
        cases
        filterOpt
        file
        index
    None => match pair
      TestPairErr message =>
        protocolPropResults engines message userDecls cases filterOpt
      TestPair _runtimeM rawCoreM coreM rawM modsM =>
        runValidatedPropEnginesGo
          engines
          helpers
          rejected
          rawCoreM
          coreM
          rawM
          modsM
          target
          tsrc
          userDecls
          cases
          filterOpt
          file
          index

-- If elaborating a generated bridge changes diagnostics outside its synthetic
-- source location, only properties which need a bridge become protocol rows.
-- Structural properties continue against the original graph.
runProtocolHelperEngines : List Engine ->
  TestPair ->
  String ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List PropResult
runProtocolHelperEngines [] _ _ _ _ _ _ _ _ _ = []
runProtocolHelperEngines engines (TestPairErr err) _ _ _ userDecls cases filterOpt _ _ =
  protocolPropResults engines err userDecls cases filterOpt
runProtocolHelperEngines engines (TestPair _runtimeM rawCoreM coreM rawM modsM) message target tsrc userDecls cases filterOpt file index =
  runProtocolHelperEnginesGo
    engines
    message
    rawCoreM
    coreM
    rawM
    modsM
    target
    tsrc
    userDecls
    cases
    filterOpt
    file
    index

runProtocolHelperEnginesGo : List Engine ->
  String ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List (String, List Decl) ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List PropResult
runProtocolHelperEnginesGo [] _ _ _ _ _ _ _ _ _ _ _ _ = []
runProtocolHelperEnginesGo (engine :: rest) message rawCoreM coreM rawM modsM target tsrc userDecls cases filterOpt file index =
  let engineText = engineName engine
  let requests = propRequestsFor index file engineText userDecls cases filterOpt
  let root = rootPlanModuleId rawM target
  let modules = planModules rawCoreM coreM rawM modsM
  let next =
    runProtocolHelperEnginesGo
      rest
      message
      rawCoreM
      coreM
      rawM
      modsM
      target
      tsrc
      userDecls
      cases
      filterOpt
      file
      index
  match (preparePlannedPropRequests
    root
    modules
    requests
    (elaboratedRootProps modsM userDecls))
    Err err =>
      preparedResults (map (preparedPlanError engineText err) requests) ++ next
    Ok (env, prepared) =>
      let rows = rejectPreparedProtocolCustom env engineText message prepared
      let here = match engine
        EngInterp =>
          runPreparedPropRequestsResults
            env
            []
            rows
            (propLineTests tsrc)
            (evalModulesRootEvalEnvWith (testCapableExterns ()) coreM modsM)
            (coreM ++ flatMap snd modsM)
        EngNative => runPreparedNativeRows rows target tsrc modules
      here ++ next

runValidatedPropEnginesGo : List Engine ->
  List PropHelper ->
  OrdMap String ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List (String, List Decl) ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List PropResult
runValidatedPropEnginesGo [] _helpers _rejected _rawCoreM _coreM _rawM _modsM _target _tsrc _userDecls _cases _filterOpt _file _index =
  []
runValidatedPropEnginesGo (engine :: rest) helpers rejected rawCoreM coreM rawM modsM target tsrc userDecls cases filterOpt file index =
  let engineText = engineName engine
  let requests = propRequestsFor index file engineText userDecls cases filterOpt
  let root = rootPlanModuleId rawM target
  let modules = planModules rawCoreM coreM rawM modsM
  match (preparePlannedPropRequests
    root
    modules
    requests
    (elaboratedRootProps modsM userDecls))
    Err err =>
      preparedResults (map (preparedPlanError engineText err) requests)
        ++ runValidatedPropEnginesGo
          rest
          helpers
          rejected
          rawCoreM
          coreM
          rawM
          modsM
          target
          tsrc
          userDecls
          cases
          filterOpt
          file
          index
    Ok (env, prepared) =>
      let rows = rejectPreparedHelpers env engineText rejected prepared
      let here = match engine
        EngInterp =>
          runPreparedPropRequestsResults
            env
            helpers
            rows
            (propLineTests tsrc)
            (evalModulesRootEvalEnvWith (testCapableExterns ()) coreM modsM)
            (coreM ++ flatMap snd modsM)
        EngNative => runPreparedNativeRows rows target tsrc modules
      here
        ++ runValidatedPropEnginesGo
          rest
          helpers
          rejected
          rawCoreM
          coreM
          rawM
          modsM
          target
          tsrc
          userDecls
          cases
          filterOpt
          file
          index

runPreparedNativeRows : List PreparedPropRequest ->
  String ->
  String ->
  List PlanModule ->
  <IO> List PropResult
runPreparedNativeRows rows target tsrc modules =
  mergeNativePreparedRows
    rows
    (runNativePlannedPropRequests target tsrc modules (preparedRequests rows))

preparedRequests : List PreparedPropRequest -> List PropRequest
preparedRequests [] = []
preparedRequests ((PreparedRun request _ _) :: rest) =
  request :: preparedRequests rest
preparedRequests (_ :: rest) = preparedRequests rest

preparedResults : List PreparedPropRequest -> List PropResult
preparedResults [] = []
preparedResults ((PreparedResult result) :: rest) =
  result :: preparedResults rest
preparedResults (_ :: rest) = preparedResults rest

mergeNativePreparedRows : List PreparedPropRequest ->
  List PropResult ->
  List PropResult
mergeNativePreparedRows [] [] = []
mergeNativePreparedRows [] (_ :: _) = [unexpectedNativeProtocolResult]
mergeNativePreparedRows ((PreparedResult result) :: rest) native =
  propResultForEngine "native" result :: mergeNativePreparedRows rest native
mergeNativePreparedRows ((PreparedRun request _ _) :: rest) [] =
  nativeProtocolResult request :: mergeNativePreparedRows rest []
mergeNativePreparedRows ((PreparedRun _ _ _) :: rest) (native :: nativeRest) =
  native :: mergeNativePreparedRows rest nativeRest

preparedPlanError : String -> PlanError -> PropRequest -> PreparedPropRequest
preparedPlanError engine err (PropRequest name seed cases) =
  PreparedResult
    (PropResult
      engine
      name
      PropErroredResult
      (Some PropCapabilityError)
      (planErrorText err)
      seed
      cases)

rejectPreparedHelpers : PlanEnv ->
  String ->
  OrdMap String ->
  List PreparedPropRequest ->
  List PreparedPropRequest
rejectPreparedHelpers _ _ _ [] = []
rejectPreparedHelpers env engine rejected ((row@(PreparedResult _)) :: rest) =
  row :: rejectPreparedHelpers env engine rejected rest
rejectPreparedHelpers env engine rejected ((row@(PreparedRun request _ plans)) :: rest) =
  let next = rejectPreparedHelpers env engine rejected rest
  if plansHaveNoRejectedCarrier env rejected plans then
    row :: next
  else
    PreparedResult (helperCapabilityResult env engine request rejected plans)
      :: next

rejectPreparedProtocolCustom : PlanEnv ->
  String ->
  String ->
  List PreparedPropRequest ->
  List PreparedPropRequest
rejectPreparedProtocolCustom _ _ _ [] = []
rejectPreparedProtocolCustom env engine message ((row@(PreparedResult _)) :: rest) =
  row :: rejectPreparedProtocolCustom env engine message rest
rejectPreparedProtocolCustom env engine message ((row@(PreparedRun request _ plans)) :: rest) =
  let next = rejectPreparedProtocolCustom env engine message rest
  match customPlansReachable env plans
    [] => row :: next
    _ => PreparedResult (helperProtocolResult engine message request) :: next

helperProtocolResult : String -> String -> PropRequest -> PropResult
helperProtocolResult engine message (PropRequest name seed cases) =
  PropResult
    engine
    name
    PropErroredResult
    (Some PropProtocolError)
    message
    seed
    cases

helperCapabilityResult : PlanEnv ->
  String ->
  PropRequest ->
  OrdMap String ->
  List GenPlan ->
  PropResult
helperCapabilityResult env engine (PropRequest name seed cases) rejected plans =
  match firstRejectedCarrier rejected (customPlansReachable env plans)
    Some (CustomPlan _ carrier word) =>
      let detail = match omLookup word rejected
        Some message => message
        None => "typed helper could not be elaborated"
      let err =
        PlanError name "$property-helper" carrier PEUnusableArbitrary detail
      PropResult
        engine
        name
        PropErroredResult
        (Some PropCapabilityError)
        (planErrorText err)
        seed
        cases
    None =>
      PropResult
        engine
        name
        PropErroredResult
        (Some PropProtocolError)
        "property helper rejection lost its carrier"
        seed
        cases

firstRejectedCarrier : OrdMap String -> List CustomPlan -> Option CustomPlan
firstRejectedCarrier _ [] = None
firstRejectedCarrier rejected ((custom@(CustomPlan _ _ word)) :: rest)
  | omHasKey word rejected = Some custom
  | otherwise = firstRejectedCarrier rejected rest

nativeProtocolResult : PropRequest -> PropResult
nativeProtocolResult (PropRequest name seed cases) =
  PropResult
    "native"
    name
    PropErroredResult
    (Some PropProtocolError)
    "native property runner returned no selected result"
    seed
    cases

unexpectedNativeProtocolResult : PropResult
unexpectedNativeProtocolResult =
  PropResult
    "native"
    "<native property runner>"
    PropErroredResult
    (Some PropProtocolError)
    "native property runner returned an unexpected selected result"
    0
    0

propResultForEngine : String -> PropResult -> PropResult
propResultForEngine engine (PropResult _ name status kind detail seed cases) =
  PropResult engine name status kind detail seed cases

protocolPropResults : List Engine ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  List PropResult
protocolPropResults [] _ _ _ _ = []
protocolPropResults (engine :: rest) message userDecls cases filterOpt =
  protocolPropsForEngine
      (engineName engine)
      message
      (filterPropsByName filterOpt (filterProps userDecls))
      cases
    ++ protocolPropResults rest message userDecls cases filterOpt

protocolPropsForEngine : String -> String -> List Decl -> Int -> List PropResult
protocolPropsForEngine _ _ [] _ = []
protocolPropsForEngine engine message ((DProp _ name _ _) :: rest) cases =
  PropResult
      engine
      name
      PropErroredResult
      (Some PropProtocolError)
      message
      (propSeedValue ())
      cases
    :: protocolPropsForEngine engine message rest cases
protocolPropsForEngine engine message (_ :: rest) cases =
  protocolPropsForEngine engine message rest cases

-- The loader and elaborator produce these graphs in the same dependency-first
-- order. Keep the source declarations beside their elaborated counterparts so
-- native property planning retains spelling while it keys semantics by the
-- resolved declarations; do not reconstruct names from mangled runtime tags.
planModules : List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List (String, List Decl) ->
  List PlanModule
planModules rawCore coreM rawModules runtimeModules =
  PlanModule "core" rawCore coreM :: planModulesGo rawModules runtimeModules

planModulesGo : List (String, List Decl) ->
  List (String, List Decl) ->
  List PlanModule
planModulesGo [] [] = []
planModulesGo ((_rawId, rawDecls) :: rawRest) ((runtimeId, runtimeDecls) :: runtimeRest) =
  PlanModule runtimeId rawDecls runtimeDecls
    :: planModulesGo rawRest runtimeRest
planModulesGo _ _ = []

rootPlanModuleId : List (String, List Decl) -> String -> String
rootPlanModuleId [] fallback = fallback
rootPlanModuleId [(moduleId, _)] _ = moduleId
rootPlanModuleId (_ :: rest) fallback = rootPlanModuleId rest fallback

propRequestsFor : PinIndex ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  List PropRequest
propRequestsFor index file engine userDecls cases filterOpt =
  propRequestsForGo
    index
    file
    engine
    (propSeedValue ())
    cases
    (filterPropsByName filterOpt (filterProps userDecls))

propRequestsForGo : PinIndex ->
  String ->
  String ->
  Int ->
  Int ->
  List Decl ->
  List PropRequest
propRequestsForGo _ _ _ _ _ [] = []
propRequestsForGo index file engine seed cases ((DProp _ name _ _) :: rest) =
  let request = match pinFromIndex index file PropPin name engine
    Some pin => PropRequest name (pinSeedOr seed pin) (pinCasesOr cases pin)
    None => PropRequest name seed cases
  request :: propRequestsForGo index file engine seed cases rest
propRequestsForGo index file engine seed cases (_ :: rest) =
  propRequestsForGo index file engine seed cases rest

pinSeedOr : Int -> TestPin -> Int
pinSeedOr fallback pin = match pin.pinSeed
  Some seed => seed
  None => fallback

pinCasesOr : Int -> TestPin -> Int
pinCasesOr fallback pin = match pin.pinCases
  Some cases => cases
  None => fallback

-- ── test-decl phase as pure data (#2295 (d)) ────────────────────────────────
-- Symmetric with `propsReport` above: the same single-file/multi-module split
-- `runTestDecls` uses, but collecting a `(name, line, ExResult)` per `test
-- "…"` decl instead of printing.  Exists so `medaka test --json` can report
-- the SAME `test "…"` counts the human runner does — `runTestReport`'s
-- structured contract (medaka mcp's medaka_test, #1443) deliberately excludes
-- this phase entirely (see `runTestReport`'s `includeTestDecls` parameter),
-- so this is a second, CLI-only consumer of the same discovery/eval
-- machinery, not a change to what medaka_test reports.  `filterOpt` mirrors
-- `runTestDecls`' `filterTestsByName` (F1).
--
-- #2588: each result carries the `Engine` that produced it, so `--json` can tag
-- it.  Under `--engines eval,native` a file's tests appear once per engine —
-- the same test judged twice is two results, not one, because that is exactly
-- the disagreement a second engine exists to expose.
testDeclsReportPinned : List Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List (Engine, String, Int, ExResult)
testDeclsReportPinned engines pair runtimeDecls target tsrc userDecls filterOpt file index
  | not (hasTests userDecls) = []
  | otherwise =
    testDeclsReportEngines
      engines
      pair
      runtimeDecls
      target
      tsrc
      userDecls
      filterOpt
      file
      index

testDeclsReportEngines : List Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List (Engine, String, Int, ExResult)
testDeclsReportEngines [] _ _ _ _ _ _ _ _ = []
testDeclsReportEngines (e :: rest) pair runtimeDecls target tsrc userDecls filterOpt file index =
  map
      (t => tagWithEngine e t)
      (testDeclsReportOn
        e
        pair
        runtimeDecls
        target
        tsrc
        userDecls
        filterOpt
        file
        index)
    ++ testDeclsReportEngines
      rest
      pair
      runtimeDecls
      target
      tsrc
      userDecls
      filterOpt
      file
      index

tagWithEngine : Engine ->
  (String, Int, ExResult) ->
  (Engine, String, Int, ExResult)
tagWithEngine e (name, line, result) = (e, name, line, result)

testDeclsReportOn : Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  String ->
  PinIndex ->
  <IO> List (String, Int, ExResult)
testDeclsReportOn EngInterp (TestPairErr _) _runtimeDecls _target _tsrc _userDecls _filterOpt _file _index =
  []
testDeclsReportOn EngInterp (TestPair _runtimeM _rawCoreM coreM _rawM modsM) runtimeDecls target tsrc userDecls filterOpt _file _index =
  gatedTestsCollect
    target
    (runtimeDecls ++ coreM ++ flatMap snd modsM)
    (evalModulesRootEvalEnvWith (testCapableExterns ()) coreM modsM)
    (rootTestsOf filterOpt tsrc modsM userDecls)
testDeclsReportOn EngNative _pair _runtimeDecls target tsrc _userDecls filterOpt file index =
  let tests = filterTestsByName filterOpt (nativeRawTests tsrc)
  let ordinary = filterList (notExpectedNativeError index file) tests
  nativeTestsWithPinnedErrors
    target
    tsrc
    index
    file
    tests
    (runNativeTests target tsrc ordinary)

notExpectedNativeError : PinIndex -> String -> (String, Int, Expr) -> Bool
notExpectedNativeError index file (name, _, _) =
  not (isExpectedNativeError index file name)

isExpectedNativeError : PinIndex -> String -> String -> Bool
isExpectedNativeError index file name =
  match pinFromIndex index file TestPin name "native"
    Some pin => match pin.pinExpected
      Some (ExpectError _) => True
      _ => False
    None => False

-- An expected native abort receives its own probe, while all ordinary tests
-- remain one compiled batch. Recombine by source tuple so later ordinary tests
-- cannot vanish behind the known abort and duplicate unpinned names stay ordered.
nativeTestsWithPinnedErrors : String ->
  String ->
  PinIndex ->
  String ->
  List (String, Int, Expr) ->
  List ExResult ->
  <IO> List (String, Int, ExResult)
nativeTestsWithPinnedErrors _ _ _ _ [] _ = []
nativeTestsWithPinnedErrors target tsrc index file ((selected@(name, line, _)) :: rest) ordinary =
  if isExpectedNativeError
    index
    file
    name then match runNativeTests target tsrc [selected]
    [result] =>
      (name, line, result)
        :: nativeTestsWithPinnedErrors target tsrc index file rest ordinary
    _ =>
      (name, line, Errored "native test runner returned no selected result")
        :: nativeTestsWithPinnedErrors target tsrc index file rest ordinary
  else match ordinary
    [] =>
      (name, line, Errored "native test runner returned no selected result")
        :: nativeTestsWithPinnedErrors target tsrc index file rest []
    result :: ordinaryRest =>
      (name, line, result)
        :: nativeTestsWithPinnedErrors target tsrc index file rest ordinaryRest

-- The `--json` twin of `gatedReportTests`: the capability refusal reaches this
-- surface as one `Errored` per test carrying the same message, so a machine
-- reader sees `"status":"error"` with the offending extern named rather than a
-- silently empty `tests` array.
gatedTestsCollect : String ->
  List Decl ->
  EvalEnv (Value e) ->
  List (String, Int, Expr) ->
  <e> List (String, Int, ExResult)
gatedTestsCollect target corpus env tests =
  match uncapableExternsEnv corpus env tests
    [] => runTestsCollectEnv env tests
    names =>
      let msg = uncapableExternsMsg target names
      map (t => (fst3 t, snd3 t, Errored msg)) tests

snd3 : (a, b, c) -> b
snd3 (_, b, _) = b

runTestsCollectEnv : EvalEnv (Value e) ->
  List (String, Int, Expr) ->
  <e> List (String, Int, ExResult)
runTestsCollectEnv _ [] = []
runTestsCollectEnv env ((name, line, body) :: rest) =
  (name, line, runOneTestEnv env body) :: runTestsCollectEnv env rest

-- ── test: flags, engine selection, --json rendering ─────────────────────
-- Moved from `driver/medaka_cli.mdk` (S-test-verb): the engine/flag
-- vocabulary and the `--json` envelope for `medaka test`. The verb's entry
-- point (`runTestCmd`/`runTestJsonCmd`/`runTestManyTargets`) stays in
-- `medaka_cli.mdk` because it calls `requireArgs`/`dieMsg`, both defined
-- there and shared across verbs; routing those calls through here would
-- make this file import `driver.medaka_cli` while `medaka_cli.mdk` already
-- imports this module, a cycle `driver/loader.mdk` rejects.

export
testHelpText : String
testHelpText = stringConcat [
  "medaka test — Run doctests + property tests\n", "\n", "Usage:\n",
  "  medaka test [--native | --engines eval,native] [--json] [--filter <substring>]\n",
  "              [--seed <n>] [--cases <n>] [file.mdk | dir]\n", "\n",
  "  --native            run doctests, properties and `test \"…\"` decls through a\n",
  "                      compiled native binary (the default; shorthand\n",
  "                      for --engines native)\n",
  "  --engines e1,e2,...  run the listed engine set (known: eval, native);\n",
  "                      exit code is the AND across engines. `eval` is\n",
  "                      the interpreter; property tests follow this selection\n",
  "  --json               emit a {\"file\":...,\"engine\":...,\"doctests\":...,\n",
  "                      \"properties\":...,\"tests\":...,\"summary\":...} JSON\n",
  "                      object instead of human text (single file.mdk target\n",
  "                      only; agrees with the human report's pass/fail counts\n",
  "                      on all three phases)\n",
  "  --filter <substring> restrict to doctests/`test \"…\"`/`prop \"…\"` whose\n",
  "                      name (or, for a doctest, input expression) contains\n",
  "                      <substring>\n",
  "  --seed <n>           seed the property-test RNG (printed on every prop\n",
  "                      failure so the counterexample is replayable); never\n",
  "                      affects a program under test's own random draws\n",
  "  --cases <n>           run each property with <n> generated cases\n",
  "                      instead of the default 100\n", "\n",
  "--native and --engines are mutually exclusive. With neither, the default\n",
  "is the native backend alone.\n", "\n",
  "With no target, tests the project containing the current directory: the\n",
  "nearest directory at or above it with a medaka.toml, walked like a dir\n",
  "target. Outside any project, pass a file.mdk or dir target.\n"
]

-- #2316: any `--`-prefixed token must be one of the known `medaka test`
-- flags. The pre-#2316 `testTargets` fallthrough (`startsWith "--" x =
-- testTargets rest`) dropped ANY unrecognized `--`-shaped token
-- unconditionally — so `--engines=native` (the `=`-form, which nothing then
-- parsed as `--engines`) silently vanished, `parseTestEngines` saw no
-- `--engines`/`--native` at all, and the run fell back to the default engine and
-- exited 0 with no diagnostic.  The spec below is what rejects it now.
-- Declaration order is the roster order, reproducing the old
-- `testBoolFlags ++ testValueFlags` rendering.
--
-- `--seed`/`--cases` are `value`, not `intValue`, and `--engines` is `value`,
-- not `oneOf`: their rejection sentences are `parseTestIntFlag`'s and
-- `parseEngineNames`'s own hand-written ones, and this slice keeps every one
-- of them verbatim (convergence onto `args.mdk`'s `invalidValueMessage` is a
-- later decision, not this slice's).
-- `withStrictDash` (S-5, #2355 residual A): an undeclared `-x` would otherwise fall
-- through as a target path (AS-FILENAME); now C2-rejected like `--x`.
export
testArgSpec : ArgSpec
testArgSpec =
  withStrictDash
    (spec "test" [
      switch ["--native"] "shorthand for --engines native",
      switch ["--json"] "emit the structured-diagnostics envelope",
      value ["--engines"] "eval,native" "engines to run each example under",
      value ["--filter"] "SUBSTRING" "run only matching examples",
      value ["--seed"] "N" "seed the property RNG",
      value ["--cases"] "N" "property cases per test",
      internal
        (switch
          ["--props-worker"]
          "INTERNAL: run isolated interpreter properties"),
    ])

-- `--cases <n>`/`--seed <n>` must parse as integers — same "named + located"
-- rejection style as an unknown engine name (`parseEngineNames`), not a
-- silent fall-through to the default.
export
parseTestIntFlag : String -> Args -> Result String (Option Int)
parseTestIntFlag nm a = match flagValue nm a
  None => Ok None
  Some s => match toInt s
    Some n => Ok (Some n)
    None => Err "\{nm} requires an integer value, got '\{s}'"

-- `--cases 0`/`--cases -3` parse as integers but `findFailure`'s `run >
-- maxTests` guard makes any `n <= 0` an instant vacuous pass (0 draws,
-- exit 0) — reject non-positive `--cases` the same "named + located" way
-- as an unparseable one, instead of silently degrading to a vacuous green.
export
parseTestCasesFlag : Args -> Result String (Option Int)
parseTestCasesFlag a = match parseTestIntFlag "--cases" a
  Err msg => Err msg
  Ok None => Ok None
  Ok (Some n) =>
    if n <= 0 then
      Err "--cases requires a positive integer value, got '\{intToString n}'"
    else
      Ok (Some n)

-- `--engines <list>` and `--native` are MUTUALLY EXCLUSIVE — not "--engines
-- silently wins". Letting one silently override the other reproduces, in
-- miniature, the exact "flag quietly does something other than what the user
-- asked" failure the whole --native/--engines split exists to remove: a user
-- who typed --native and got only `--engines`'s answer, with no diagnostic,
-- has no way to know --native was ignored. So both together is a hard error
-- naming both flags, not a silent pick.  With neither given, the default is
-- `[EngNative]`: the engine `medaka build` ships, so a test observes the
-- tail-call and TRMC space laws (docs/spec/EMITTER-SEMANTICS.md §6) and the
-- host externs the interpreter does not bind.
export
parseTestEngines : Args -> Result String (List Engine)
parseTestEngines a = match (flagValue "--engines" a, flag "--native" a)
  (Some _, True) =>
    Err
      "--native and --engines are mutually exclusive; --native is shorthand for --engines native"
  (Some spec, False) => parseEngineList spec
  (None, True) => Ok [EngNative]
  (None, False) => Ok [EngNative]

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
parseEngineNames (n :: rest) = match engineOfName n
  None => Err "unknown engine '\{n}' (known: eval, native)"
  Some e => map (e :: _) (parseEngineNames rest)

engineOfName : String -> Option Engine
engineOfName "eval" = Some EngInterp
engineOfName "native" = Some EngNative
engineOfName _ = None

-- `testFlagValue`/`testTargets` are gone: `Args.positionals` is exactly the
-- non-flag args minus every value-taking flag's VALUE, and `flagValue` is the
-- first-occurrence read they performed.  Their final `startsWith "--"` arms
-- were already unreachable (the flag floor ran first), so nothing that could
-- silently drop a token survives.

-- Original single-file path, unchanged: read <MEDAKA_ROOT>/stdlib sources,
-- build search roots, run `runTest`, exit 1 on any failure/read-error.
export
runTestOne : List Engine -> Int -> Option String -> String -> <IO> Unit
runTestOne engines cases filterOpt target =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  let stdlibDir = root ++ "/stdlib"
  let roots = entrySearchRoots (dirOf target) ++ [stdlibDir]
  let ok = runTest engines rtPath corePath target roots cases filterOpt
  if ok then () else exit 1

export
cliTestReportOk : Option String ->
  List (Engine, RunResult) ->
  List PropResult ->
  List (Engine, String, Int, ExResult) ->
  Bool
cliTestReportOk typeError runs props tests =
  isNone typeError
    && cliAllDoctestRunsOk runs
    && cliAllPropsPass props
    && cliAllTestsPass tests

cliAllDoctestRunsOk : List (Engine, RunResult) -> Bool
cliAllDoctestRunsOk [] = True
cliAllDoctestRunsOk ((_, run) :: rest) =
  runFailed run == 0 && runErrors run == 0 && cliAllDoctestRunsOk rest

cliAllPropsPass : List PropResult -> Bool
cliAllPropsPass [] = True
cliAllPropsPass (p :: rest) = propResultPassed p && cliAllPropsPass rest

cliAllTestsPass : List (Engine, String, Int, ExResult) -> Bool
cliAllTestsPass [] = True
cliAllTestsPass ((_, _, _, Pass _ _) :: rest) = cliAllTestsPass rest
cliAllTestsPass (_ :: _) = False

cliPrimaryDoctestRun : List (Engine, RunResult) -> RunResult
cliPrimaryDoctestRun [] = RunResult 0 0 0 0 []
cliPrimaryDoctestRun ((_, run) :: _) = run

cliCountPassProps : List PropResult -> Int
cliCountPassProps [] = 0
cliCountPassProps (p :: rest) =
  (if propResultPassed p then 1 else 0) + cliCountPassProps rest

cliCountFailProps : List PropResult -> Int
cliCountFailProps [] = 0
cliCountFailProps (p :: rest) =
  (if propResultPassed p then 0 else 1) + cliCountFailProps rest

cliCountPassTests : List (Engine, String, Int, ExResult) -> Int
cliCountPassTests [] = 0
cliCountPassTests ((_, _, _, Pass _ _) :: rest) = 1 + cliCountPassTests rest
cliCountPassTests (_ :: rest) = cliCountPassTests rest

cliCountFailTests : List (Engine, String, Int, ExResult) -> Int
cliCountFailTests [] = 0
cliCountFailTests ((_, _, _, Pass _ _) :: rest) = cliCountFailTests rest
cliCountFailTests (_ :: rest) = 1 + cliCountFailTests rest

cliExampleJson : (Example, ExResult) -> Json
-- Structurally identical to mcp.mdk's `exampleJson` now that both render an
-- `ExResult` through the shared `exResultJsonFields`; the part worth sharing
-- already lives in tools/doctest.mdk, and each module owns its own `--json`
-- envelope.
-- lint-disable-next-line rule-duplicate-body
cliExampleJson (ex, res) =
  jObject
    ([("line", JInt (exampleLine ex)), ("input", JString (exampleInput ex))]
      ++ exResultJsonFields res)

cliDoctestsJson : RunResult -> Json
cliDoctestsJson run = jObject [
  ("total", JInt (runPassed run + runFailed run + runErrors run)),
  ("passed", JInt (runPassed run)),
  ("failed", JInt (runFailed run)),
  ("errors", JInt (runErrors run)),
  ("examples", jArray (map cliExampleJson (runDetails run))),
]

cliPropJson : PropResult -> Json
cliPropJson = propResultJson

-- #2588: every `test "…"` result names the engine that produced it. Under
-- `--engines eval,native` the same test appears twice, once per engine, and the
-- field is what tells the two apart; under the default single engine it still
-- says which one ran, so a reader never has to infer it from the flags.
cliTestJson : (Engine, String, Int, ExResult) -> Json
cliTestJson (engine, name, line, result) =
  jObject
    ([
        ("name", JString name),
        ("line", JInt line),
        ("engine", JString (engineName engine)),
      ]
      ++ exResultJsonFields result)

cliTypeErrorField : Option String -> List (String, Json)
cliTypeErrorField None = []
cliTypeErrorField (Some errText) = [("typeError", JString errText)]

-- F7 (#1680/#1443): present only when True — see `mcp.mdk`'s
-- `typecheckSkippedField` (the CLI JSON envelope's own twin of the human
-- arm's stderr `typecheckSkipNotice`).
cliTypecheckSkippedField : Bool -> List (String, Json)
cliTypecheckSkippedField False = []
cliTypecheckSkippedField True = [("typecheckSkipped", JBool True)]

-- #2341: which engine the (possibly type-error-short-circuited) doctest run
-- reflects, mirroring `mcp.mdk`'s `doctestRunEngineNames`/`primaryEngineName`
-- pair — not shared across a module boundary (mcp.mdk already imports
-- test_cmd.mdk, so the reverse import would cycle).
-- lint-disable-next-line rule-duplicate-body
cliDoctestRunEngineNames : List (Engine, RunResult) -> List Engine
cliDoctestRunEngineNames [] = []
cliDoctestRunEngineNames ((e, _) :: rest) = e :: cliDoctestRunEngineNames rest

-- #2341: mirrors `mcp.mdk`'s `primaryEngineName`, not shared across the
-- module boundary for the same reason as `cliDoctestRunEngineNames` above.
-- lint-disable-next-line rule-duplicate-body
cliPrimaryEngineName : List Engine -> String
cliPrimaryEngineName [] = "unknown"
cliPrimaryEngineName (e :: _) = engineName e

-- The full envelope: doctests + properties (same shape `medaka_test`'s
-- `testReportJson` uses) PLUS a `tests` array for `test "…"` decls, and a
-- `summary` folding all three phases together — this is the field
-- `testReportJson` cannot provide (it never runs this phase, by its own
-- documented scope), and the one this slice's acceptance check depends on.
--
-- `engine` names the doctest phase's PRIMARY (first-requested) engine, the
-- same field `medaka_test`'s envelope already carries (#2341) — read
-- alongside each `tests[]` entry's own per-result `engine` (#2588) and each
-- doctest `--engines` block already being labelled on the human arm, this is
-- shape parity, not new information: under multiple engines the `doctests`
-- block itself still reports only the primary engine's examples, same as
-- `medaka_test`. No separate `note` caveat is added — unlike `medaka_test`,
-- which has no other channel to say so, the CLI's own `--engines` flag is
-- the caller's own input, and each engine's block is already labelled on the
-- human arm.
export
cliTestReportJson : String ->
  Option String ->
  List Engine ->
  List (Engine, RunResult) ->
  List PropResult ->
  List (Engine, String, Int, ExResult) ->
  Bool ->
  Json
cliTestReportJson path typeError engines runs props tests typecheckSkipped =
  let runEngines =
    if isNone typeError then cliDoctestRunEngineNames runs else engines
  jObject
    ([
        ("file", JString path),
        ("engine", JString (cliPrimaryEngineName runEngines)),
      ]
      ++ cliTypeErrorField typeError
      ++ cliTypecheckSkippedField typecheckSkipped
      ++ [
        ("doctests", cliDoctestsJson (cliPrimaryDoctestRun runs)),
        ("properties", jArray (map cliPropJson props)),
        ("tests", jArray (map cliTestJson tests)),
        (
          "summary",
          jObject [
            (
              "passed",
              JInt
                (runPassed (cliPrimaryDoctestRun runs)
                  + cliCountPassProps props
                  + cliCountPassTests tests),
            ),
            (
              "failed",
              JInt
                (runFailed (cliPrimaryDoctestRun runs)
                  + runErrors (cliPrimaryDoctestRun runs)
                  + cliCountFailProps props
                  + cliCountFailTests tests),
            ),
            ("ok", JBool (cliTestReportOk typeError runs props tests)),
          ],
        ),
      ])

-- Ledger-aware JSON keeps raw operands/detail and only changes the reported
-- status for a held pin. Drained and changed pins remain failures with their
-- raw outcome visible; `issue` and `pin` explain why the command is red.
export
cliGradedTestReportOk : Option String ->
  List (Engine, RunResult) ->
  List GradedProp ->
  List GradedTest ->
  Bool
cliGradedTestReportOk reportError runs props tests =
  isNone reportError
    && cliAllDoctestRunsOk runs
    && allGradedPropsPass props
    && allGradedTestsPass tests

allGradedPropsPass : List GradedProp -> Bool
allGradedPropsPass [] = True
allGradedPropsPass (row :: rest) =
  gradedPropPassed row && allGradedPropsPass rest

allGradedTestsPass : List GradedTest -> Bool
allGradedTestsPass [] = True
allGradedTestsPass (row :: rest) =
  gradedTestPassed row && allGradedTestsPass rest

cliGradedPropJson : GradedProp -> Json
cliGradedPropJson row =
  let raw = gradedPropRaw row
  jObject
    ([
        ("engine", JString (propResultEngine raw)),
        ("name", JString (propResultName raw)),
        ("status", JString (gradedPropStatus row)),
        ("rawStatus", JString (gradedPropRawStatus row)),
        ("detail", JString (propResultDetail raw)),
        ("failureKind", propFailureKindJson (propResultFailureKind raw)),
        ("seed", JInt (propResultSeed raw)),
        ("cases", JInt (propResultCases raw)),
      ]
      ++ cliIssueField (gradedPropIssue row)
      ++ cliPinField (gradedPropPinDetail row))

cliGradedTestJson : GradedTest -> Json
cliGradedTestJson row =
  let (engine, name, line, raw) = gradedTestRaw row
  jObject
    ([
        ("name", JString name),
        ("line", JInt line),
        ("engine", JString engine),
        ("status", JString (gradedTestStatus row)),
        ("rawStatus", JString (gradedTestRawStatus row)),
      ]
      ++ cliRawTestOperands raw
      ++ cliIssueField (gradedTestIssue row)
      ++ cliPinField (gradedTestPinDetail row))

cliRawTestOperands : ExResult -> List (String, Json)
cliRawTestOperands (Pass expected actual) = [
  ("expected", JString expected),
  ("actual", JString actual),
]
cliRawTestOperands (Fail detail expected actual) =
  [("expected", JString expected), ("actual", JString actual)]
    ++ (if detail == "" then [] else [("detail", JString detail)])
cliRawTestOperands (Errored detail) = [("detail", JString detail)]

cliIssueField : Option Int -> List (String, Json)
cliIssueField None = []
cliIssueField (Some issue) = [("issue", JInt issue)]

cliPinField : Option String -> List (String, Json)
cliPinField None = []
cliPinField (Some detail) = [("pin", JString detail)]

cliCountPassedGradedProps : List GradedProp -> Int
cliCountPassedGradedProps [] = 0
cliCountPassedGradedProps (row :: rest) =
  (if propResultPassed (gradedPropRaw row) && gradedPropPassed row then
      1
    else
      0)
    + cliCountPassedGradedProps rest

cliCountFailedGradedProps : List GradedProp -> Int
cliCountFailedGradedProps [] = 0
cliCountFailedGradedProps (row :: rest) =
  (if gradedPropPassed row then 0 else 1) + cliCountFailedGradedProps rest

cliCountPassedGradedTests : List GradedTest -> Int
cliCountPassedGradedTests [] = 0
cliCountPassedGradedTests (row :: rest) =
  let (_, _, _, raw) = gradedTestRaw row
  (if rawTestPassed raw && gradedTestPassed row then 1 else 0)
    + cliCountPassedGradedTests rest

rawTestPassed : ExResult -> Bool
rawTestPassed (Pass _ _) = True
rawTestPassed _ = False

cliCountFailedGradedTests : List GradedTest -> Int
cliCountFailedGradedTests [] = 0
cliCountFailedGradedTests (row :: rest) =
  (if gradedTestPassed row then 0 else 1) + cliCountFailedGradedTests rest

export
cliGradedTestReportJson : String ->
  Option String ->
  List Engine ->
  List (Engine, RunResult) ->
  List GradedProp ->
  List GradedTest ->
  Bool ->
  Json
cliGradedTestReportJson path reportError engines runs props tests typecheckSkipped =
  let runEngines =
    if isNone reportError then cliDoctestRunEngineNames runs else engines
  let known = knownRedCountProps props + knownRedCountTests tests
  jObject
    ([
        ("file", JString path),
        ("engine", JString (cliPrimaryEngineName runEngines)),
      ]
      ++ cliTypeErrorField reportError
      ++ cliTypecheckSkippedField typecheckSkipped
      ++ [
        ("doctests", cliDoctestsJson (cliPrimaryDoctestRun runs)),
        ("properties", jArray (map cliGradedPropJson props)),
        ("tests", jArray (map cliGradedTestJson tests)),
        (
          "summary",
          jObject [
            (
              "passed",
              JInt
                (runPassed (cliPrimaryDoctestRun runs)
                  + cliCountPassedGradedProps props
                  + cliCountPassedGradedTests tests),
            ),
            (
              "failed",
              JInt
                (runFailed (cliPrimaryDoctestRun runs)
                  + runErrors (cliPrimaryDoctestRun runs)
                  + cliCountFailedGradedProps props
                  + cliCountFailedGradedTests tests),
            ),
            ("knownRed", JInt known),
            ("ok", JBool (cliGradedTestReportOk reportError runs props tests)),
          ],
        ),
      ])

-- #2589 item 2: roster-completeness for `*_test.mdk` discovery. The recursive
-- walk (`expandLintTarget`/`collectMdkFiles` in
-- `compiler/support/cli_targets.mdk`, called from `medaka_cli.mdk`'s
-- `runTestManyTargets`) already finds every
-- `_test.mdk` sibling on disk by extension alone — it cannot structurally
-- miss one (§4's "already walks `_test.mdk` siblings like any other .mdk").
-- What it CAN miss is a file that is git-TRACKED but absent from the walked
-- `files` set for some other reason (a stray symlink, a target typo, a path
-- the walk's dot-entry skip swallowed). Ported from
-- `pds/test/inlang_test_oracle_test.mdk`'s pattern — enumerate, require each
-- accounted for, fail named on a gap — WITHOUT that gate's hand-maintained
-- roster: the "expected" side here is `git ls-files` itself, so a new
-- `foo_test.mdk` needs no roster edit to be covered (#2589 item 2's
-- acceptance shape). Not a new gate script: this runs INSIDE `medaka test
-- <dir>` itself, so no new CI enrollment is needed either.
--
-- Both sides MUST be in the same path form, or every entry looks "missing"
-- on a false positive. `git ls-files` alone prints paths relative to the
-- process's CWD (not the repo root) unless told otherwise, while `files`
-- carries whatever form the CALLER's target argument was in — [T-WORKTREE-
-- PATHS] tells every agent to pass ABSOLUTE paths in a worktree, since cwd
-- resets between calls there, and `medaka test <absolute dir>` reported a
-- FALSE roster failure on an all-green run before this fix (every file
-- "git-tracked but not discovered" despite each one having just run).
-- `--full-name` makes `git ls-files` always print repo-root-relative paths
-- regardless of cwd (a pathspec can still be absolute; only the OUTPUT form
-- changes), and `stripRootPrefix` puts `files` into that same root-relative
-- form before comparing.
export
checkTestMdkRoster : String -> List String -> List String -> <IO> Bool
checkTestMdkRoster root targets files =
  match runCommand "git" (["ls-files", "--full-name", "--"] ++ targets)
    Err _ => True
    Ok (0, out, _) =>
      let tracked =
        filterList (endsWith "_test.mdk") (filterList (/= "") (splitNl out))
      let relFiles = map (stripRootPrefix root) files
      let missing = filterList (t => not (contains t relFiles)) tracked
      match missing
        [] => True
        _ =>
          let _ =
            ePutStrLn
              "medaka test: git-tracked but not discovered: \{joinWith ", " missing}"
          False
    Ok (_, _, _) => True

-- Drops a `root ++ "/"` prefix if `p` carries one, otherwise `p` unchanged
-- (already root-relative, e.g. when the caller's target was relative).
stripRootPrefix : String -> String -> String
stripRootPrefix root p =
  let prefix = root ++ "/"
  if startsWith prefix p then
    stringSlice (stringLength prefix) (stringLength p) p
  else
    p

-- Reconstructs the argv for a per-file CHILD `medaka test` invocation
-- (containment, below) from the already-resolved engine list/case
-- count/filter/seed — the same four knobs `runTestCmd` read from its OWN argv,
-- round-tripped rather than re-parsed by the child.
testChildArgs : List Engine ->
  Int ->
  Option String ->
  Option Int ->
  String ->
  List String
testChildArgs engines cases filterOpt seedOpt f =
  [
      "test",
      f,
      "--engines",
      joinWith "," (map engineName engines),
      "--cases",
      intToString cases,
    ]
    ++ (match filterOpt
      Some s => ["--filter", s]
      None => [])
    ++ (match seedOpt
      Some s => ["--seed", intToString s]
      None => [])

-- Fold over an expanded file list, aggregating whether ANY file failed
-- (tests failed, the file itself couldn't be read/parsed, or the child
-- process died). Each file runs `runTest` in its OWN child process — a
-- panic in file 3 of 20 would abort the whole in-process loop, so files
-- 4-20 print nothing (#2589 item 1). Spawning per file means a
-- dead file is contained to its own `runCommand` result: its stdout up to
-- the crash still prints, it is named DEAD in the aggregate, and the walk
-- continues. `envOr "MEDAKA" (executablePath ())` mirrors
-- `native_doctest.mdk`'s spawn precedent but defaults to the RUNNING
-- binary's own absolute path rather than a bare "medaka" that a bare `PATH`
-- lookup might resolve to a different, stale binary.
export
testFilesGo : List Engine ->
  String ->
  String ->
  String ->
  Int ->
  Option String ->
  Option Int ->
  List String ->
  Bool ->
  <IO> Bool
testFilesGo _ _ _ _ _ _ _ [] acc = acc
testFilesGo engines rtPath corePath stdlibDir cases filterOpt seedOpt (f :: rest) acc =
  let medaka = envOr "MEDAKA" (executablePath ())
  let args = testChildArgs engines cases filterOpt seedOpt f
  let ok = match runCommand medaka args
    Err e =>
      let _ = ePutStrLn "medaka test: \{f}: failed to start test runner: \{e}"
      False
    Ok (code, out, err) =>
      let _ = putStr out
      -- `putStr` writes to buffered <Stdout>; `ePutStr`/`ePutStrLn` below write
      -- straight through to unbuffered <Stderr>. Under a merged capture
      -- (`2>&1`), the stderr write can hit disk before this file's still-
      -- buffered stdout content flushes, splicing this file's DEAD notice
      -- into the MIDDLE of an earlier or later file's own output. Flushing
      -- here pins the ordering: this file's captured stdout is fully on disk
      -- before any stderr write for it (or the next file) can occur.
      let _ = flushStdout ()
      if code == 0 then
        True
      else
        let _ = ePutStr err
        let _ =
          ePutStrLn "medaka test: \{f}: DEAD (child exited \{intToString code})"
        False
  testFilesGo
    engines
    rtPath
    corePath
    stdlibDir
    cases
    filterOpt
    seedOpt
    rest
    (acc || not ok)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" false) (mem "Loc" true) (mem "Ty" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseResult" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "desugaredPreludeKey" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgramFilesLocatedE" false) (mem "modIdToPath" false) (mem "loadErrorMessage" false) (mem "LoadError" true) (mem "entrySearchRoots" false) (mem "canonicalPathId" false) (mem "readDeps" false) (mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false) (mem "readSource" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "readPreludeFile" false) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateOne" false) (mem "elaborateModules" false) (mem "TcDiag" true) (mem "tcDiagGoalKey" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "withEvidencePreserved" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "mangleCtorCollisionsPair" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" false) (mem "EvalEnv" false) (mem "evalOneRootEnvWith" false) (mem "evalModulesRootEvalEnvWith" false) (mem "evalModulesRootEnvWith" false) (mem "currentEvalFile" false) (mem "modulePathMap" false) (mem "testCapableExterns" false) (mem "funNamesOf" false) (mem "dropShadowedExp" false) (mem "lookupBinding" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" true) (mem "Engine" true) (mem "engineName" false) (mem "extractExamples" false) (mem "buildSynthResults" false) (mem "buildSynthDecls" false) (mem "buildDetailsFrom" false) (mem "doctestFailSuffix" false) (mem "hasUseDecls" false) (mem "printDoctestDetails" false) (mem "runDetails" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "synthName" false) (mem "exResultJsonFields" false))))
(DUse false (UseGroup ("tools" "native_doctest") ((mem "runNativeDoctests" false))))
(DUse false (UseGroup ("tools" "native_test_decls") ((mem "runNativeTests" false))))
(DUse false (UseGroup ("tools" "native_props") ((mem "runNativePlannedPropRequests" false))))
(DUse false (UseGroup ("tools" "prop_plan") ((mem "PlanModule" true) (mem "CustomPlan" true) (mem "GenPlan" false) (mem "PlanEnv" false) (mem "PlanError" true) (mem "PlanErrorReason" true) (mem "customPlansReachable" false) (mem "planErrorText" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "hasProps" false) (mem "runAllPlannedPropRequestsResults" false) (mem "preparePlannedPropRequests" false) (mem "runPreparedPropRequestsResults" false) (mem "PreparedPropRequest" true) (mem "PropHelper" true) (mem "PropResult" true) (mem "PropStatus" true) (mem "PropFailureKind" true) (mem "PropRequest" true) (mem "filterProps" false) (mem "filterPropsByName" false) (mem "propResultName" false) (mem "propResultPassed" false) (mem "propResultDetail" false) (mem "propResultEngine" false) (mem "propResultStatus" false) (mem "propResultSeed" false) (mem "propResultCases" false) (mem "propResultFailureKind" false) (mem "propSeedValue" false))))
(DUse false (UseGroup ("tools" "prop_helpers") ((mem "PropHelpers" true) (mem "propHelpersForPlans" false))))
(DUse false (UseGroup ("tools" "eval_props") ((mem "emitEvalPropRows" false) (mem "decodeEvalPropRows" false) (mem "propResultJson" false) (mem "propFailureKindJson" false) (mem "startEvalPropWorker" false) (mem "takeEvalPropBootstrap" false))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "firstNonEmptyLine" false))))
(DUse false (UseGroup ("tools" "test_pins") ((mem "PinIndex" false) (mem "PinKind" true) (mem "TestExpectedFailure" true) (mem "TestPin" false) (mem "buildPinIndex" false) (mem "pinFromIndex" false) (mem "validatePinNames" false))))
(DUse false (UseGroup ("tools" "test_pins_io") ((mem "loadPinContext" false))))
(DUse false (UseGroup ("tools" "test_pins_report") ((mem "GradedProp" false) (mem "GradedTest" false) (mem "gradeProps" false) (mem "gradeTests" false) (mem "gradedPropPassed" false) (mem "gradedTestPassed" false) (mem "gradedPropRaw" false) (mem "gradedTestRaw" false) (mem "gradedPropVerdict" false) (mem "gradedTestVerdict" false) (mem "knownRedCountProps" false) (mem "knownRedCountTests" false) (mem "gradedPropStatus" false) (mem "gradedPropRawStatus" false) (mem "gradedPropIssue" false) (mem "gradedPropPinDetail" false) (mem "gradedTestStatus" false) (mem "gradedTestRawStatus" false) (mem "gradedTestIssue" false) (mem "gradedTestPinDetail" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("tools" "test_runner") ((mem "collectTests" false) (mem "exprLine" false) (mem "runOneTestEnv" false) (mem "hasTests" false) (mem "uncapableExternsEnv" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeLocated" false) (mem "projectDiagsFromTc" false) (mem "projectDiagsLoaded" false) (mem "noStdlibExports" false) (mem "chainKeyOf" false) (mem "desugaredModPairs" false) (mem "mkDiag" false) (mem "Severity" true) (mem "readDiagSrc" false) (mem "ppDiagCliSrc" false) (mem "ppDiagCliLines" false) (mem "srcLinesArr" false) (mem "parseErrDiag" false) (mem "Diag" false) (mem "diagIsError" false))))
(DUse true (UseGroup ("support" "util") ((mem "rootsOrDefault" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "joinNl" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "endsWith" false) (mem "splitOnChar" false) (mem "contains" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "stringTrim" false) (mem "reverseL" false) (mem "anyList" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "baseOf" false) (mem "joinPath" false))))
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "Args" false) (mem "spec" false) (mem "switch" false) (mem "value" false) (mem "internal" false) (mem "flag" false) (mem "flagValue" false) (mem "withStrictDash" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "splitLintNames" false))))
(DUse false (UseGroup ("string") ((mem "toInt" false))))
(DTypeSig false "substringMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substringMatch" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "runTest" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTest" ((PVar "engines") (PVar "runtimeP") (PVar "coreP") (PVar "target") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EMatch (EApp (EVar "readPreludeFile") (EVar "runtimeP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "coreP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EVar "parseErrDiag") (EVar "target")) (EVar "e"))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "exemptNotice") (EVar "exempt")) (EVar "target")) (EVar "userDecls"))) (DoExpr (EMatch (EApp (EApp (EVar "pinIndexForTarget") (EVar "target")) (EVar "userDecls")) (arm (PCon "Err" (PVar "err")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "err"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PTuple (PVar "file") (PVar "index"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveAll") (EVar "engines")) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")) (EVar "exempt")) (EVar "file")) (EVar "index")))))))))))))))
(DTypeSig false "pinIndexForTarget" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "PinIndex")))))))
(DFunDef false "pinIndexForTarget" ((PVar "target") (PVar "userDecls")) (EApp (EApp (EVar "andThen") (EApp (EVar "loadPinContext") (EVar "target"))) (ELam ((PVar "context")) (ELet false (PVar "names") (EApp (EApp (EApp (EApp (EVar "validatePinNames") (EFieldAccess (EVar "context") "contextPins")) (EFieldAccess (EVar "context") "contextFile")) (EApp (EVar "propNamesOf") (EVar "userDecls"))) (EApp (EVar "testNamesOf") (EVar "userDecls"))) (EMatch (EVar "names") (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EVar "err"))) (arm (PCon "Ok" (PLit LUnit)) () (EApp (EApp (EVar "map") (ELam ((PVar "index")) (ETuple (EFieldAccess (EVar "context") "contextFile") (EVar "index")))) (EApp (EVar "buildPinIndex") (EFieldAccess (EVar "context") "contextPins")))))))))
(DTypeSig false "typecheckExempt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "typecheckExempt" ((PVar "target") (PVar "userDecls") (PVar "tsrc")) (EIf (EApp (EVar "isNonEmptyL") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (EVar "False") (EIf (EApp (EVar "isNewVehiclePath") (EVar "target")) (EVar "False") (EIf (EVar "otherwise") (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EApp (EVar "hasTests") (EVar "userDecls"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isNewVehiclePath" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "isNewVehiclePath" ((PVar "target")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "target")) (EBlock (DoLet false false (PVar "canon") (EApp (EVar "canonicalizePath") (EVar "target"))) (DoExpr (EBinOp "||" (EBinOp "||" (EApp (EVar "hasVehicleSegment") (EVar "canon")) (EApp (EVar "underProjectTestDir") (EVar "canon"))) (EApp (EVar "underMedakaRepoTestDir") (EVar "canon"))))) (EVar "False")))
(DTypeSig false "hasVehicleSegment" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasVehicleSegment" ((PVar "path")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (ELam ((PVar "seg")) (EBinOp "||" (EBinOp "==" (EVar "seg") (ELit (LString "compiler"))) (EBinOp "==" (EVar "seg") (ELit (LString "stdlib")))))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path")))))
(DTypeSig false "underProjectTestDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "underProjectTestDir" ((PVar "target")) (EBlock (DoLet false false (PVar "d") (EApp (EVar "dirOf") (EVar "target"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "baseOf") (EVar "d")) (ELit (LString "test"))) (EMatch (EApp (EVar "findProjectRoot") (EVar "d")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))) (EVar "False")))))
(DTypeSig false "underMedakaRepoTestDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "underMedakaRepoTestDir" ((PVar "target")) (EBlock (DoLet false false (PVar "d") (EApp (EVar "dirOf") (EVar "target"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "baseOf") (EVar "d")) (ELit (LString "test"))) (EApp (EVar "fileExists") (EApp (EApp (EVar "joinPath") (EApp (EVar "dirOf") (EVar "d"))) (ELit (LString "compiler/medaka.toml"))))))))
(DTypeSig false "exemptNotice" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "exemptNotice" ((PCon "False") PWild PWild) (ELit LUnit))
(DFunDef false "exemptNotice" ((PCon "True") (PVar "target") (PVar "userDecls")) (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckSkipNotice") (EVar "target")) (EVar "userDecls"))))
(DTypeSig false "singleFileTypeErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "singleFileTypeErrors" ((PVar "target") (PVar "tsrc") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EApp (EApp (EApp (EApp (EVar "analyzeLocated") (EVar "noStdlibExports")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs")))))))))
(DTypeSig false "gateOfPerModule" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "gateOfPerModule" ((PCon "True") PWild PWild PWild PWild) (EVar "None"))
(DFunDef false "gateOfPerModule" ((PCon "False") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "mods") (PVar "perModule")) (EApp (EVar "renderGate") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDiagsFromTc") (EVar "noStdlibExports")) (EVar "True")) (EListLit)) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "mods")) (EVar "perModule"))))
(DTypeSig false "loadGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "loadGate" ((PCon "True") PWild PWild) (EVar "None"))
(DFunDef false "loadGate" ((PCon "False") (PVar "target") (PVar "le")) (EApp (EVar "renderGate") (EApp (EApp (EVar "loadErrorDiags") (EVar "target")) (EVar "le"))))
(DTypeSig false "loadErrorDiags" (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "loadErrorDiags" (PWild (PCon "LoadParseFailed" (PVar "mpath") PWild (PVar "pe"))) (EListLit (ETuple (EVar "mpath") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "mpath")) (EVar "pe"))))))
(DFunDef false "loadErrorDiags" ((PVar "target") (PCon "LoadCycle" (PVar "e") (PVar "cpath") (PVar "csite"))) (EMatch (EVar "csite") (arm (PCon "Some" (PTuple PWild (PVar "loc"))) () (EListLit (ETuple (EVar "cpath") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "e")) (EApp (EVar "Some") (EVar "loc"))))))) (arm (PCon "None") () (EListLit (ETuple (EVar "target") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "e")) (EVar "None"))))))))
(DFunDef false "loadErrorDiags" ((PVar "target") (PCon "LoadMsg" (PVar "e"))) (EListLit (ETuple (EVar "target") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "e")) (EVar "None"))))))
(DTypeSig false "renderGate" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "renderGate" ((PVar "results")) (EMatch (EApp (EApp (EVar "flatMap") (EVar "renderFileErrors")) (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EVar "results"))) (arm (PList) () (EVar "None")) (arm (PVar "rendered") () (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "rendered"))))))
(DTypeSig false "renderFileErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderFileErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EVar "diags"))))
(DTypeSig false "typecheckGateFail" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typecheckGateFail" ((PVar "target") (PVar "errText")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type error in ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString " — `medaka test` requires it to `medaka check` first:\n"))) (EApp (EVar "display") (EVar "errText"))) (ELit (LString ""))))
(DTypeSig false "typecheckSkipNotice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "typecheckSkipNotice" ((PVar "target") (PVar "userDecls")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "note: typechecking was skipped for ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString "\n  reason: the module declares "))) (EApp (EVar "display") (EApp (EVar "skipReasonDecls") (EVar "userDecls")))) (ELit (LString " and no doctests, so `medaka test` exempts it from the type checker (issue #1229) — those phases exist to exercise eval on constructs `medaka check` rejects.\n  a runtime error below may therefore be an uncaught TYPE error.\n  to type-check it: medaka check "))) (EApp (EVar "display") (EVar "target"))) (ELit (LString ""))))
(DTypeSig false "skipReasonDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "skipReasonDecls" ((PVar "userDecls")) (EIf (EBinOp "&&" (EApp (EVar "hasTests") (EVar "userDecls")) (EApp (EVar "hasProps") (EVar "userDecls"))) (ELit (LString "`test \"…\"` and `prop \"…\"` decls")) (EIf (EApp (EVar "hasTests") (EVar "userDecls")) (ELit (LString "`test \"…\"` decls")) (EIf (EVar "otherwise") (ELit (LString "`prop \"…\"` decls")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "filterMatchedNothing" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))))
(DFunDef false "filterMatchedNothing" ((PCon "None") PWild PWild) (EVar "False"))
(DFunDef false "filterMatchedNothing" ((PCon "Some" (PVar "sub")) (PVar "tsrc") (PVar "userDecls")) (EApp (EVar "not") (EBinOp "||" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterExamplesByName") (EApp (EVar "Some") (EVar "sub"))) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterPropsByName") (EApp (EVar "Some") (EVar "sub"))) (EApp (EVar "filterProps") (EVar "userDecls"))))) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterTestsByName") (EApp (EVar "Some") (EVar "sub"))) (EApp (EVar "nativeRawTests") (EVar "tsrc")))))))
(DData Private "TestPair" () ((variant "TestPair" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))) (variant "TestPairErr" (ConPos (TyCon "String")))) ())
(DData Private "HelperValidation" () ((variant "HelperValidation" (ConPos (TyCon "TestPair") (TyApp (TyCon "List") (TyCon "PropHelper")) (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))) ())
(DData Private "DoctestTrees" () ((variant "DtPair" (ConPos (TyCon "TestPair"))) (variant "DtSingle" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DData Private "Prepared" () ((variant "PreparedPair" (ConPos (TyCon "TestPair"))) (variant "PreparedInject" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DTypeSig false "prepareMulti" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Prepared")))))))))))
(DFunDef false "prepareMulti" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "exempt") (PVar "hasDoctests") (PVar "synthDecls")) (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "le")) () (ETuple (EApp (EApp (EApp (EVar "loadGate") (EVar "exempt")) (EVar "target")) (EVar "le")) (EApp (EVar "PreparedPair") (EApp (EVar "TestPairErr") (EApp (EVar "loadErrorMessage") (EVar "le")))))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "modulePathMap")) (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EVar "mods")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "elaborateFor") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "mods")) (EVar "exempt")) (EVar "hasDoctests")) (EVar "synthDecls")))))))
(DTypeSig false "elaborateFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Prepared"))))))))))))
(DFunDef false "elaborateFor" ((PVar "rsrc") (PVar "csrc") (PVar "_target") (PVar "_roots") (PVar "mods") (PVar "exempt") (PCon "False") PWild) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (DoLet false false (PVar "rawModules") (EApp (EVar "desugaredModPairs") (EVar "mods"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "rawModules")) (arm (PTuple (PVar "coreE") (PVar "modulesE") (PVar "perModule") PWild PWild PWild) () (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "gateOfPerModule") (EVar "exempt")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "mods")) (EVar "perModule")) (EApp (EVar "PreparedPair") (EApp (EApp (EApp (EApp (EVar "uncurryPair") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "rawModules")) (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE")))))))))))
(DFunDef false "elaborateFor" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "mods") (PVar "exempt") (PCon "True") (PVar "synthDecls")) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "gateOfCheck") (EVar "exempt")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "mods")) (EApp (EApp (EVar "PreparedInject") (EVar "mods")) (EVar "synthDecls"))))
(DTypeSig false "forcePrepared" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Prepared") (TyEffect ("IO") None (TyCon "TestPair"))))))
(DFunDef false "forcePrepared" (PWild PWild (PCon "PreparedPair" (PVar "pair"))) (EVar "pair"))
(DFunDef false "forcePrepared" ((PVar "rsrc") (PVar "csrc") (PCon "PreparedInject" (PVar "mods") (PVar "synthDecls"))) (EBlock (DoLet false false (PVar "injected") (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EApp (EVar "desugaredModPairs") (EVar "mods")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "injected")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild PWild PWild PWild) () (EApp (EApp (EApp (EApp (EVar "uncurryPair") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "injected")) (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE")))))))))
(DTypeSig false "gateOfCheck" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "gateOfCheck" ((PCon "True") PWild PWild PWild PWild PWild) (EVar "None"))
(DFunDef false "gateOfCheck" ((PCon "False") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "mods")) (EApp (EVar "renderGate") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDiagsLoaded") (EVar "noStdlibExports")) (EVar "True")) (EListLit)) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EApp (EVar "Some") (ETuple (EApp (EVar "desugaredPreludeKey") (EVar "rsrc")) (EApp (EVar "desugaredPreludeKey") (EVar "csrc"))))) (EApp (EApp (EVar "chainKeyOf") (EVar "target")) (EVar "roots"))) (EVar "mods"))))
(DTypeSig false "uncurryPair" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyCon "TestPair"))))))
(DFunDef false "uncurryPair" ((PVar "runtimeDecls") (PVar "rawCore") (PVar "rawModules") (PTuple (PVar "core") (PVar "mods"))) (EApp (EApp (EApp (EApp (EApp (EVar "TestPair") (EVar "runtimeDecls")) (EVar "rawCore")) (EVar "core")) (EVar "rawModules")) (EVar "mods")))
(DTypeSig false "prepareSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "TestPair"))))))))
(DFunDef false "prepareSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "roots") (PVar "userDecls")) (EBlock (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "modulePathMap")) (EListLit (ETuple (EVar "rootId") (EVar "target"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "uncurryPair") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls")))) (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))))))
(DTypeSig false "driveAll" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyCon "Bool")))))))))))))))))
(DFunDef false "driveAll" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls") (PVar "exempt") (PVar "file") (PVar "index")) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveMulti") (EVar "engines")) (EVar "runtimeDecls")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")) (EVar "exempt")) (EVar "file")) (EVar "index")) (EIf (EVar "otherwise") (EMatch (EIf (EVar "exempt") (EVar "None") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "rsrc")) (EVar "csrc"))) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "errText")))) (DoExpr (EVar "False")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveSingle") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")) (EVar "file")) (EVar "index")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "driveMulti" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyCon "Bool"))))))))))))))))
(DFunDef false "driveMulti" ((PVar "engines") (PVar "runtimeDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls") (PVar "exempt") (PVar "file") (PVar "index")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoLet false false (PVar "allExamples") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EVar "allExamples"))) (DoLet false false (PVar "synthResults") (EApp (EApp (EVar "buildSynthResults") (EVar "userDecls")) (EVar "examples"))) (DoLet false false (PVar "synthDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults"))) (DoLet false false (PVar "gated") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prepareMulti") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "exempt")) (EApp (EVar "isNonEmptyL") (EVar "allExamples"))) (EVar "synthDecls"))) (DoExpr (EMatch (EVar "gated") (arm (PTuple (PCon "Some" (PVar "errText")) PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "errText")))) (DoExpr (EVar "False")))) (arm (PTuple (PCon "None") (PVar "prepared")) () (EIf (EApp (EApp (EApp (EVar "filterMatchedNothing") (EVar "filterOpt")) (EVar "tsrc")) (EVar "userDecls")) (EBlock (DoLet false false PWild (EApp (EVar "filterMatchedNothingNotice") (EVar "target"))) (DoExpr (EVar "False"))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EVar "forcePrepared") (EVar "rsrc")) (EVar "csrc")) (EVar "prepared"))) (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "engines")) (EApp (EVar "DtPair") (EVar "pair"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropsPinned") (EVar "engines")) (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsPinned") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk"))))))))))
(DTypeSig false "driveSingle" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyCon "Bool"))))))))))))))
(DFunDef false "driveSingle" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls") (PVar "file") (PVar "index")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoExpr (EIf (EApp (EApp (EApp (EVar "filterMatchedNothing") (EVar "filterOpt")) (EVar "tsrc")) (EVar "userDecls")) (EBlock (DoLet false false PWild (EApp (EVar "filterMatchedNothingNotice") (EVar "target"))) (DoExpr (EVar "False"))) (EBlock (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "engines")) (EApp (EApp (EApp (EApp (EApp (EVar "DtSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EApp (EApp (EVar "buildSynthResults") (EVar "userDecls")) (EVar "examples")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EApp (EVar "hasTests") (EVar "userDecls"))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EApp (EApp (EVar "prepareSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropsPinned") (EVar "engines")) (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsPinned") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk")))) (EVar "doctestsOk"))))))))
(DTypeSig false "filterMatchedNothingNotice" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "filterMatchedNothingNotice" ((PVar "target")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": --filter matched no doctests, props, or `test \"…\"` decls")))))
(DTypeSig false "filterExamplesByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyCon "Example")))))
(DFunDef false "filterExamplesByName" ((PCon "None") (PVar "examples")) (EVar "examples"))
(DFunDef false "filterExamplesByName" ((PCon "Some" (PVar "sub")) (PVar "examples")) (EApp (EApp (EVar "filterList") (ELam ((PVar "ex")) (EApp (EApp (EVar "substringMatch") (EVar "sub")) (EApp (EVar "exampleInput") (EVar "ex"))))) (EVar "examples")))
(DTypeSig false "runDoctests" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runDoctests" ((PVar "engines") (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running doctests in ")) (EVar "target")))) (DoExpr (EMatch (EVar "examples") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  (no doctests found)")))) (DoExpr (EVar "True")))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEngines") (EVar "engines")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))))))
(DTypeSig false "runEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runEngines" ((PList (PVar "e")) (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EVar "reportDoctests") (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))))
(DFunDef false "runEngines" ((PVar "engines") (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEnginesTagged") (EVar "engines")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))
(DTypeSig false "runEnginesTagged" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runEnginesTagged" ((PList) PWild PWild PWild PWild PWild PWild) (EVar "True"))
(DFunDef false "runEnginesTagged" ((PCons (PVar "e") (PVar "rest")) (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "-- ")) (EApp (EVar "display") (EApp (EVar "engineName") (EVar "e")))) (ELit (LString " --"))))) (DoLet false false (PVar "ok") (EApp (EApp (EVar "reportDoctests") (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))) (DoLet false false (PVar "restOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEnginesTagged") (EVar "rest")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (DoExpr (EBinOp "&&" (EVar "ok") (EVar "restOk")))))
(DTypeSig true "runChosenOn" (TyFun (TyCon "Engine") (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult"))))))))))
(DFunDef false "runChosenOn" ((PCon "EngInterp") (PVar "trees") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EVar "runChosen") (EVar "trees")) (EVar "examples")) (EVar "synthResults")))
(DFunDef false "runChosenOn" ((PCon "EngNative") (PVar "_trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EVar "runNativeDoctests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))
(DTypeSig false "runChosen" (TyFun (TyCon "DoctestTrees") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult"))))))
(DFunDef false "runChosen" ((PCon "DtPair" (PCon "TestPairErr" (PVar "e"))) (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Err") (EVar "e"))) (EVar "synthResults")) (EVar "examples")))
(DFunDef false "runChosen" ((PCon "DtPair" (PCon "TestPair" (PVar "_runtimeM") (PVar "_rawCoreM") (PVar "coreM") (PVar "_rawM") (PVar "modsM"))) (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "synthResults")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))
(DFunDef false "runChosen" ((PCon "DtSingle" (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "roots") (PVar "userDecls")) (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "allUser") (EBinOp "++" (EVar "userDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults")))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EApp (EVar "funNamesOf") (EVar "allUser"))) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "modulePathMap")) (EListLit (ETuple (ELit (LString "__main__")) (EVar "target"))))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateOne") (EVar "runtimeDecls")) (EVar "livePrelude")) (ETuple (EVar "rootId") (EVar "allUser")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalOneRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EListLit)) (ETuple (ELit (LString "__main__")) (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "synthResults")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))
(DTypeSig false "renderExamples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "renderExamples" ((PVar "env") (PVar "synthResults") (PVar "examples")) (EApp (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (EVar "synthResults")) (ELit (LInt 0))) (EVar "examples")))
(DTypeSig false "renderExamplesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))))
(DFunDef false "renderExamplesGo" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "renderExamplesGo" ((PVar "env") (PCons (PVar "sr") (PVar "srRest")) (PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "renderOneExample") (EVar "env")) (EVar "sr")) (EVar "i")) (EVar "ex")) (EApp (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (EVar "srRest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DFunDef false "renderExamplesGo" ((PVar "env") (PList) (PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "renderOneExample") (EVar "env")) (EApp (EVar "Err") (ELit (LString "")))) (EVar "i")) (EVar "ex")) (EApp (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (EListLit)) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "renderOneExample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "renderOneExample" ((PVar "env") (PVar "sr") (PVar "i") (PVar "ex")) (EMatch (EApp (EApp (EVar "lookupBinding") (EApp (EVar "synthName") (EVar "i"))) (EVar "env")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "could not evaluate: ")) (EApp (EVar "exampleInput") (EVar "ex"))))) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EApp (EVar "firstUnresolvedDottedRef") (EVar "env")) (EVar "sr")) (arm (PCon "Some" (PVar "name")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not evaluate: ")) (EApp (EVar "display") (EApp (EVar "exampleInput") (EVar "ex")))) (ELit (LString " (unresolved: "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ")"))))) (arm (PCon "None") () (EApp (EVar "Ok") (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))))))))
(DTypeSig false "firstUnresolvedDottedRef" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "firstUnresolvedDottedRef" (PWild (PCon "Err" PWild)) (EVar "None"))
(DFunDef false "firstUnresolvedDottedRef" ((PVar "env") (PCon "Ok" (PVar "ds"))) (EApp (EApp (EVar "firstUnresolvedName") (EVar "env")) (EApp (EApp (EVar "flatMap") (EVar "declRefs")) (EVar "ds"))))
(DTypeSig false "firstUnresolvedName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "firstUnresolvedName" (PWild (PList)) (EVar "None"))
(DFunDef false "firstUnresolvedName" ((PVar "env") (PCons (PVar "n") (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EVar "isDottedRef") (EVar "n")) (EApp (EVar "isNone") (EApp (EApp (EVar "lookupBinding") (EVar "n")) (EVar "env")))) (EApp (EVar "Some") (EVar "n")) (EIf (EVar "otherwise") (EApp (EApp (EVar "firstUnresolvedName") (EVar "env")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isDottedRef" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDottedRef" ((PVar "n")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (ELit (LString "."))) (EVar "n"))))
(DTypeSig true "singleRootId" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "singleRootId" ((PVar "roots") (PVar "target")) (EBlock (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "target"))))) (DoExpr (EApp (EApp (EApp (EVar "canonicalPathId") (EVar "deps")) (EVar "roots")) (EVar "target")))))
(DTypeSig false "programIsCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "programIsCore" ((PVar "prog")) (EBinOp "&&" (EApp (EVar "pcHasOrdering") (EVar "prog")) (EApp (EVar "pcHasFoldable") (EVar "prog"))))
(DTypeSig false "pcHasOrdering" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "pcHasOrdering" ((PList)) (EVar "False"))
(DFunDef false "pcHasOrdering" ((PCons (PRec "DData" ((rf "dataName" (PLit (LString "Ordering")))) false) PWild)) (EVar "True"))
(DFunDef false "pcHasOrdering" ((PCons PWild (PVar "rest"))) (EApp (EVar "pcHasOrdering") (EVar "rest")))
(DTypeSig false "pcHasFoldable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "pcHasFoldable" ((PList)) (EVar "False"))
(DFunDef false "pcHasFoldable" ((PCons (PRec "DInterface" ((rf "name" (PLit (LString "Foldable")))) true) PWild)) (EVar "True"))
(DFunDef false "pcHasFoldable" ((PCons PWild (PVar "rest"))) (EApp (EVar "pcHasFoldable") (EVar "rest")))
(DTypeSig false "injectIntoLast" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "injectIntoLast" (PWild (PList)) (EListLit))
(DFunDef false "injectIntoLast" ((PVar "synthDecls") (PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EBinOp "++" (EVar "decls") (EVar "synthDecls")))))
(DFunDef false "injectIntoLast" ((PVar "synthDecls") (PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EVar "rest"))))
(DTypeSig false "reportDoctests" (TyFun (TyCon "String") (TyFun (TyCon "RunResult") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "reportDoctests" ((PVar "target") (PVar "result")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "printDoctestDetails") (EVar "target")) (EApp (EVar "runDetails") (EVar "result")))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "result")) (EApp (EVar "runFailed") (EVar "result"))) (EApp (EVar "runErrors") (EVar "result")))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "runPassed") (EVar "result"))))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " passed"))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "doctestFailSuffix") (EVar "result")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "runFailed") (EVar "result")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "runErrors") (EVar "result")) (ELit (LInt 0)))))))
(DTypeSig false "propLineTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "propLineTests" ((PVar "tsrc")) (EApp (EVar "collectPropLines") (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "tsrc")))))
(DTypeSig false "collectPropLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "collectPropLines" ((PList)) (EListLit))
(DFunDef false "collectPropLines" ((PCons (PCon "DProp" PWild (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "exprLine") (EVar "body"))) (EApp (EVar "collectPropLines") (EVar "rest"))))
(DFunDef false "collectPropLines" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectPropLines") (EVar "rest")))
(DTypeSig false "elaborateModulesMangled" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "elaborateModulesMangled" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild PWild PWild PWild) () (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE"))))))
(DTypeSig false "runPropsPinned" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyCon "Bool"))))))))))))
(DFunDef false "runPropsPinned" ((PVar "engines") (PVar "pair") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EVar "True") (EIf (EVar "otherwise") (EMatch (EVar "pair") (arm (PCon "TestPairErr" (PVar "err")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "err"))) (DoExpr (EVar "False")))) (arm (PCon "TestPair" (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) () (EApp (EVar "withEvidencePreserved") (ELam (PWild) (EApp (EVar "printGradedPropRows") (EApp (EApp (EApp (EVar "gradeProps") (EVar "index")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEngines") (EVar "engines")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printGradedPropRows" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "printGradedPropRows" ((PList)) (EVar "True"))
(DFunDef false "printGradedPropRows" ((PCons (PVar "row") (PVar "rest"))) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "gradedPropRaw") (EVar "row"))) (DoLet false false (PVar "rawDetail") (EMatch (EApp (EVar "gradedPropPinDetail") (EVar "row")) (arm (PCon "Some" (PVar "pin")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "propResultDetail") (EVar "raw")))) (ELit (LString "; "))) (EApp (EVar "display") (EVar "pin"))) (ELit (LString "")))) (arm (PCon "None") () (EApp (EVar "propResultDetail") (EVar "raw"))))) (DoLet false false (PVar "detail") (EIf (EBinOp "&&" (EApp (EVar "propResultPassed") (EVar "raw")) (EBinOp "==" (EVar "rawDetail") (ELit (LString "")))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "propResultCases") (EVar "raw"))))) (ELit (LString " tests passed"))) (EVar "rawDetail"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Testing \"")) (EApp (EVar "display") (EApp (EVar "propResultName") (EVar "raw")))) (ELit (LString "\" ["))) (EApp (EVar "display") (EApp (EVar "propResultEngine") (EVar "raw")))) (ELit (LString "] ... "))) (EApp (EVar "display") (EIf (EApp (EVar "gradedPropPassed") (EVar "row")) (ELit (LString "OK")) (ELit (LString "FAILED"))))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "detail"))) (ELit (LString ")"))))) (DoLet false false (PVar "restPassed") (EApp (EVar "printGradedPropRows") (EVar "rest"))) (DoExpr (EBinOp "&&" (EApp (EVar "gradedPropPassed") (EVar "row")) (EVar "restPassed")))))
(DTypeSig false "elaboratedRootProps" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "elaboratedRootProps" ((PVar "modules") (PVar "userDecls")) (EMatch (EApp (EVar "lastModule") (EVar "modules")) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls"))))
(DTypeSig false "lastModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "lastModule" ((PList)) (EVar "None"))
(DFunDef false "lastModule" ((PList (PTuple PWild (PVar "decls")))) (EApp (EVar "Some") (EVar "decls")))
(DFunDef false "lastModule" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModule") (EVar "rest")))
(DTypeSig false "runTestDeclsPinned" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyCon "Bool"))))))))))))
(DFunDef false "runTestDeclsPinned" ((PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt") (PVar "file") (PVar "index")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "printGradedTestRows") (EVar "target")) (EApp (EApp (EApp (EVar "gradeTests") (EVar "index")) (EVar "file")) (EApp (EVar "testRowsForPins") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportPinned") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printGradedTestRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "printGradedTestRows" (PWild (PList)) (EVar "True"))
(DFunDef false "printGradedTestRows" ((PVar "target") (PCons (PVar "row") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "raw")) (EApp (EVar "gradedTestRaw") (EVar "row"))) (DoLet false false (PVar "label") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " ["))) (EApp (EVar "display") (EVar "engine"))) (ELit (LString "]")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "printTestRunning") (EVar "target")) (EVar "line")) (EVar "label"))) (DoLet false false PWild (EIf (EBinOp "==" (EApp (EVar "gradedTestStatus") (EVar "row")) (ELit (LString "known-red"))) (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  known-red ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "label"))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EVar "gradedTestPinDetailText") (EVar "row")))) (ELit (LString ")")))) (EApp (EApp (EApp (EApp (EVar "printTestVerdict") (EVar "target")) (EVar "line")) (EVar "label")) (EVar "raw")))) (DoLet false false (PVar "restPassed") (EApp (EApp (EVar "printGradedTestRows") (EVar "target")) (EVar "rest"))) (DoExpr (EBinOp "&&" (EApp (EVar "gradedTestPassed") (EVar "row")) (EVar "restPassed")))))
(DTypeSig false "gradedTestPinDetailText" (TyFun (TyCon "GradedTest") (TyCon "String")))
(DFunDef false "gradedTestPinDetailText" ((PVar "row")) (EMatch (EApp (EVar "gradedTestPinDetail") (EVar "row")) (arm (PCon "Some" (PVar "detail")) () (EVar "detail")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "testRowsForPins" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))
(DFunDef false "testRowsForPins" ((PList)) (EListLit))
(DFunDef false "testRowsForPins" ((PCons (PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "result")) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EVar "engineName") (EVar "engine")) (EVar "name") (EVar "line") (EVar "result")) (EApp (EVar "testRowsForPins") (EVar "rest"))))
(DTypeSig false "rootTestsOf" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))))
(DFunDef false "rootTestsOf" ((PVar "filterOpt") (PVar "tsrc") (PVar "modsM") (PVar "userDecls")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))))))
(DTypeSig false "nativeRawTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "nativeRawTests" ((PVar "tsrc")) (EApp (EVar "collectTests") (EApp (EVar "parseLocated") (EVar "tsrc"))))
(DTypeSig false "testLineTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "testLineTests" ((PVar "tsrc")) (EApp (EVar "collectTests") (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "tsrc")))))
(DTypeSig false "filterTestsByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))
(DFunDef false "filterTestsByName" ((PCon "None") (PVar "tests")) (EVar "tests"))
(DFunDef false "filterTestsByName" ((PCon "Some" (PVar "sub")) (PVar "tests")) (EApp (EApp (EVar "filterList") (ELam ((PVar "t")) (EApp (EApp (EVar "substringMatch") (EVar "sub")) (EApp (EVar "fst3") (EVar "t"))))) (EVar "tests")))
(DTypeSig false "fst3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "a")))
(DFunDef false "fst3" ((PTuple (PVar "a") PWild PWild)) (EVar "a"))
(DTypeSig false "attachRawLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))
(DFunDef false "attachRawLines" (PWild (PList)) (EListLit))
(DFunDef false "attachRawLines" ((PList) (PCons (PTuple (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (ELit (LInt 0)) (EVar "body")) (EApp (EApp (EVar "attachRawLines") (EListLit)) (EVar "rest"))))
(DFunDef false "attachRawLines" ((PCons (PTuple PWild (PVar "l") PWild) (PVar "rawRest")) (PCons (PTuple (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "l") (EVar "body")) (EApp (EApp (EVar "attachRawLines") (EVar "rawRest")) (EVar "rest"))))
(DTypeSig false "uncapableExternsMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "uncapableExternsMsg" ((PVar "target") (PVar "names")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": `test \"…\"` declarations here reach "))) (EApp (EVar "display") (EApp (EVar "externWord") (EVar "names")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "joinCommas") (EVar "names")))) (ELit (LString ", which `medaka test` does not provide under the interpreter — its capability policy covers the clock, allocation counts and stderr only, so no filesystem, environment, stdin, network or subprocess extern is bound. No test was run. Run these tests natively instead: `medaka test --native "))) (EApp (EVar "display") (EVar "target"))) (ELit (LString "`."))))
(DTypeSig false "externWord" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "externWord" ((PList PWild)) (ELit (LString "the extern")))
(DFunDef false "externWord" (PWild) (ELit (LString "the externs")))
(DTypeSig false "joinCommas" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinCommas" ((PList)) (ELit (LString "")))
(DFunDef false "joinCommas" ((PList (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))))
(DFunDef false "joinCommas" ((PCons (PVar "n") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`, "))) (EApp (EVar "joinCommas") (EVar "rest"))))
(DTypeSig false "printTestRunning" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "printTestRunning" ((PVar "target") (PVar "line") (PVar "name")) (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  running ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "indentVerdictMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "indentVerdictMsg" ((PVar "msg")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "       ")) (EVar "_s")))) (EApp (EVar "splitNl") (EVar "msg")))))
(DTypeSig false "printTestVerdict" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "ExResult") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "printTestVerdict" ((PVar "target") (PVar "line") (PVar "name") (PVar "result")) (EBlock (DoLet false false (PVar "loc") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString "")))) (DoExpr (EMatch (EVar "result") (arm (PCon "Pass" PWild PWild) () (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ok   ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (arm (PCon "Fail" (PVar "msg") PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "putStrLn") (EApp (EVar "indentVerdictMsg") (EVar "msg")))))) (arm (PCon "Errored" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "putStrLn") (EApp (EVar "indentVerdictMsg") (EVar "msg"))))))))))
(DTypeSig true "runTestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))
(DFunDef false "runTestReport" ((PVar "engines") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "target") (PVar "tsrc") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestReportPinned") (EVar "engines")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "target")) (EVar "tsrc")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (ELit (LString ""))) (EVar "omEmpty")))
(DTypeSig false "runTestReportPinned" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))))
(DFunDef false "runTestReportPinned" ((PVar "engines") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "target") (PVar "tsrc") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportMulti") (EVar "engines")) (EVar "runtimeDecls")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (EVar "userDecls")) (EVar "exempt")) (EVar "file")) (EVar "index")) (EMatch (EIf (EVar "exempt") (EVar "None") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (arm (PCon "Some" (PVar "errText")) () (ETuple (EApp (EVar "Some") (EVar "errText")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportSingle") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (EVar "userDecls")) (EVar "exempt")) (EVar "file")) (EVar "index"))))))))
(DTypeSig true "runTestGradedReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "GradedProp")) (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Bool")))))))))))))
(DFunDef false "runTestGradedReport" ((PVar "engines") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "target") (PVar "tsrc") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls")) (ELet false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc"))) (EMatch (EApp (EVar "loadPinContext") (EVar "target")) (arm (PCon "Err" (PVar "err")) () (ETuple (EApp (EVar "Some") (EVar "err")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "Ok" (PVar "context")) () (EMatch (EApp (EApp (EApp (EApp (EVar "validatePinNames") (EFieldAccess (EVar "context") "contextPins")) (EFieldAccess (EVar "context") "contextFile")) (EApp (EVar "propNamesOf") (EVar "userDecls"))) (EApp (EVar "testNamesOf") (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (ETuple (EApp (EVar "Some") (EVar "err")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "Ok" (PLit LUnit)) () (EMatch (EApp (EVar "buildPinIndex") (EFieldAccess (EVar "context") "contextPins")) (arm (PCon "Err" (PVar "err")) () (ETuple (EApp (EVar "Some") (EVar "err")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "Ok" (PVar "index")) () (EBlock (DoLet false false (PTuple (PVar "reportError") (PVar "runs") (PVar "props") (PVar "tests") (PVar "skipped")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestReportPinned") (EVar "engines")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "target")) (EVar "tsrc")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (EFieldAccess (EVar "context") "contextFile")) (EVar "index"))) (DoExpr (ETuple (EVar "reportError") (EVar "runs") (EApp (EApp (EApp (EVar "gradeProps") (EVar "index")) (EFieldAccess (EVar "context") "contextFile")) (EVar "props")) (EApp (EApp (EApp (EVar "gradeTests") (EVar "index")) (EFieldAccess (EVar "context") "contextFile")) (EApp (EVar "testRowsForPins") (EVar "tests"))) (EVar "skipped"))))))))))))
(DTypeSig false "propNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "propNamesOf" ((PList)) (EListLit))
(DFunDef false "propNamesOf" ((PCons (PCon "DProp" PWild (PVar "name") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "name") (EApp (EVar "propNamesOf") (EVar "rest"))))
(DFunDef false "propNamesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "propNamesOf") (EVar "rest")))
(DTypeSig false "testNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "testNamesOf" ((PList)) (EListLit))
(DFunDef false "testNamesOf" ((PCons (PCon "DTest" PWild (PVar "name") PWild) (PVar "rest"))) (EBinOp "::" (EVar "name") (EApp (EVar "testNamesOf") (EVar "rest"))))
(DFunDef false "testNamesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "testNamesOf") (EVar "rest")))
(DTypeSig false "reportMulti" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool"))))))))))))))))))
(DFunDef false "reportMulti" ((PVar "engines") (PVar "runtimeDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls") (PVar "userDecls") (PVar "exempt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "allExamples") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EVar "allExamples"))) (DoLet false false (PVar "synthResults") (EApp (EApp (EVar "buildSynthResults") (EVar "userDecls")) (EVar "examples"))) (DoLet false false (PVar "prepared") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prepareMulti") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "exempt")) (EApp (EVar "isNonEmptyL") (EVar "allExamples"))) (EApp (EVar "buildSynthDecls") (EVar "synthResults")))) (DoExpr (EMatch (EVar "prepared") (arm (PTuple (PCon "Some" (PVar "errText")) PWild) () (ETuple (EApp (EVar "Some") (EVar "errText")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PTuple (PCon "None") (PVar "prepared")) () (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EVar "forcePrepared") (EVar "rsrc")) (EVar "csrc")) (EVar "prepared"))) (DoExpr (ETuple (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReport") (EVar "engines")) (EApp (EVar "DtPair") (EVar "pair"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportPinned") (EVar "engines")) (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportTestDecls") (EVar "includeTestDecls")) (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EVar "index")) (EVar "exempt")))))))))
(DTypeSig false "reportSingle" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))))))
(DFunDef false "reportSingle" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls") (PVar "userDecls") (PVar "exempt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoLet false false (PVar "doctestRuns") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReport") (EVar "engines")) (EApp (EApp (EApp (EApp (EApp (EVar "DtSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EApp (EApp (EVar "buildSynthResults") (EVar "userDecls")) (EVar "examples")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EBinOp "&&" (EVar "includeTestDecls") (EApp (EVar "hasTests") (EVar "userDecls")))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EApp (EApp (EVar "prepareSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (DoExpr (ETuple (EVar "None") (EVar "doctestRuns") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportPinned") (EVar "engines")) (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportTestDecls") (EVar "includeTestDecls")) (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EVar "index")) (EVar "exempt")))) (ETuple (EVar "None") (EVar "doctestRuns") (EListLit) (EListLit) (EVar "exempt"))))))
(DTypeSig false "reportTestDecls" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))))))))))
(DFunDef false "reportTestDecls" ((PCon "False") PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "reportTestDecls" ((PCon "True") (PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt") (PVar "file") (PVar "index")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportPinned") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EVar "index")))
(DTypeSig false "doctestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))))))))))))
(DFunDef false "doctestReport" ((PVar "engines") (PVar "_trees") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PList) (PVar "_synthResults")) (EApp (EVar "emptyDoctestRuns") (EVar "engines")))
(DFunDef false "doctestReport" ((PVar "engines") (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "engines")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))
(DTypeSig false "emptyDoctestRuns" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult")))))
(DFunDef false "emptyDoctestRuns" ((PList)) (EListLit))
(DFunDef false "emptyDoctestRuns" ((PCons (PVar "e") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (EApp (EVar "emptyDoctestRuns") (EVar "rest"))))
(DTypeSig false "doctestReportGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))))))))))))
(DFunDef false "doctestReportGo" ((PList) PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "doctestReportGo" ((PCons (PVar "e") (PVar "rest")) (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "rest")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))))
(DTypeSig false "propsReportPinned" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))
(DFunDef false "propsReportPinned" ((PVar "engines") (PVar "pair") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EListLit) (EIf (EVar "otherwise") (EMatch (EVar "pair") (arm (PCon "TestPairErr" PWild) () (EListLit)) (arm (PCon "TestPair" (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) () (EApp (EVar "withEvidencePreserved") (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEngines") (EVar "engines")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "propsReportEnginesInProcess" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))))))
(DFunDef false "propsReportEnginesInProcess" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "propsReportEnginesInProcess" ((PVar "engines") (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "planningRequests") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EVar "index")) (EVar "file")) (ELit (LString "eval"))) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "planningRequests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEnginesPlain") (EVar "engines")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))) (arm (PCon "Ok" (PTuple (PVar "planEnv") (PVar "planningRows"))) () (EBlock (DoLet false false (PVar "plans") (EApp (EVar "preparedPlans") (EVar "planningRows"))) (DoExpr (EMatch (EApp (EApp (EVar "customPlansReachable") (EVar "planEnv")) (EVar "plans")) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEnginesPlain") (EVar "engines")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))) (arm PWild () (EBlock (DoLet false false (PVar "validation") (EApp (EApp (EApp (EApp (EApp (EVar "validateHelperPlans") (EVar "planEnv")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EVar "plans"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runValidatedPropEngines") (EVar "engines")) (EVar "validation")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index")))))))))))))
(DTypeSig false "propsReportEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))))))
(DFunDef false "propsReportEngines" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "propsReportEngines" ((PCons (PCon "EngInterp") (PVar "rest")) (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBinOp "++" (EApp (EApp (EVar "superviseEvalProps") (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EVar "index")) (EVar "file")) (ELit (LString "eval"))) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEngines") (EVar "rest")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))))
(DFunDef false "propsReportEngines" ((PCons (PCon "EngNative") (PVar "rest")) (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEnginesInProcess") (EListLit (EVar "EngNative"))) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEngines") (EVar "rest")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))))
(DTypeSig false "superviseEvalProps" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))
(DFunDef false "superviseEvalProps" (PWild (PList)) (EListLit))
(DFunDef false "superviseEvalProps" ((PVar "target") (PVar "requests")) (EBlock (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EVar "executablePath") (ELit LUnit)))) (DoLet false false (PVar "argv") (EBinOp "++" (EListLit (ELit (LString "test")) (ELit (LString "--props-worker"))) (EApp (EApp (EVar "workerPositionals") (EVar "target")) (EVar "requests")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "medaka")) (EVar "argv")) (arm (PCon "Err" (PVar "message")) () (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EBinOp "++" (EBinOp "++" (ELit (LString "could not start interpreter property worker: ")) (EApp (EVar "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "stdout") (PVar "stderr"))) () (EMatch (EApp (EVar "takeEvalPropBootstrap") (EVar "stdout")) (arm (PCon "Err" (PVar "message")) () (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EVar "workerProtocolRows") (EVar "requests")) (EVar "message")) (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EApp (EApp (EVar "workerAbortDetail") (EVar "code")) (EVar "stderr"))))) (arm (PCon "Ok" (PTuple (PVar "nonce") (PVar "transcript"))) () (EMatch (EApp (EApp (EApp (EVar "decodeEvalPropRows") (EVar "nonce")) (EVar "requests")) (EVar "transcript")) (arm (PCon "Ok" (PVar "rows")) () (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EVar "rows") (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EApp (EApp (EVar "workerAbortDetail") (EVar "code")) (EVar "stderr"))))) (arm (PCon "Err" (PVar "message")) () (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EVar "workerProtocolRows") (EVar "requests")) (EVar "message")) (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EApp (EApp (EVar "workerAbortDetail") (EVar "code")) (EVar "stderr")))))))))))))
(DTypeSig false "workerAbortDetail" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "workerAbortDetail" ((PVar "code") (PVar "stderr")) (EBlock (DoLet false false (PVar "first") (EApp (EVar "firstNonEmptyLine") (EApp (EVar "splitNl") (EVar "stderr")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property worker batch aborted (exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))) (EIf (EBinOp "==" (EVar "first") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString " — ")) (EApp (EVar "display") (EVar "first"))) (ELit (LString ""))))))))
(DTypeSig false "workerPositionals" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "workerPositionals" ((PVar "target") (PVar "requests")) (EBinOp "::" (EVar "target") (EApp (EVar "workerRequestPositionals") (EVar "requests"))))
(DTypeSig false "workerRequestPositionals" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "workerRequestPositionals" ((PList)) (EListLit))
(DFunDef false "workerRequestPositionals" ((PCons (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "name"))) (EBinOp "::" (EApp (EVar "stringify") (EApp (EVar "JString") (EApp (EVar "intToString") (EVar "seed")))) (EBinOp "::" (EApp (EVar "stringify") (EApp (EVar "JString") (EApp (EVar "intToString") (EVar "cases")))) (EApp (EVar "workerRequestPositionals") (EVar "rest"))))))
(DTypeSig false "workerRuntimeRows" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "PropResult")))))
(DFunDef false "workerRuntimeRows" ((PList) PWild) (EListLit))
(DFunDef false "workerRuntimeRows" ((PCons (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases")) (PVar "rest")) (PVar "message")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropRuntimeError"))) (EVar "message")) (EVar "seed")) (EVar "cases")) (EApp (EApp (EVar "workerRuntimeRows") (EVar "rest")) (EVar "message"))))
(DTypeSig false "workerProtocolRows" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "PropResult")))))
(DFunDef false "workerProtocolRows" ((PList) PWild) (EListLit))
(DFunDef false "workerProtocolRows" ((PCons (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases")) (PVar "rest")) (PVar "message")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EVar "message")) (EVar "seed")) (EVar "cases")) (EApp (EApp (EVar "workerProtocolRows") (EVar "rest")) (EVar "message"))))
(DTypeSig true "runEvalPropsWorker" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runEvalPropsWorker" ((PVar "target") (PVar "requests")) (EBlock (DoLet false false (PVar "nonce") (EApp (EVar "startEvalPropWorker") (ELit LUnit))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "runtimePath") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "runtimePath")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "evalWorkerDie") (EBinOp "++" (EBinOp "++" (ELit (LString "could not read runtime prelude: ")) (EApp (EVar "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "runtimeSrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "evalWorkerDie") (EBinOp "++" (EBinOp "++" (ELit (LString "could not read core prelude: ")) (EApp (EVar "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "coreSrc")) () (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "evalWorkerDie") (EBinOp "++" (EBinOp "++" (ELit (LString "could not read property target: ")) (EApp (EVar "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" PWild) () (EApp (EVar "evalWorkerDie") (ELit (LString "could not parse property target")))) (arm (PCon "Ok" (PVar "parsed")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPropsWorkerSource") (EVar "target")) (EVar "nonce")) (EVar "requests")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "tsrc")) (EApp (EVar "desugar") (EVar "parsed"))))))))))))))
(DTypeSig false "evalWorkerDie" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "evalWorkerDie" ((PVar "message")) (ELet false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test --props-worker: ")) (EApp (EVar "display") (EVar "message"))) (ELit (LString "")))) (EApp (EVar "exit") (ELit (LInt 1)))))
(DTypeSig false "runEvalPropsWorkerSource" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit")))))))))))
(DFunDef false "runEvalPropsWorkerSource" ((PVar "target") (PVar "nonce") (PVar "requests") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "tsrc") (PVar "userDecls")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoExpr (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EBlock (DoLet false false (PVar "prepared") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prepareMulti") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "target")) (EVar "roots")) (EVar "exempt")) (EVar "False")) (EListLit))) (DoExpr (EMatch (EVar "prepared") (arm (PTuple (PCon "Some" (PVar "message")) PWild) () (EApp (EVar "evalWorkerDie") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "message")))) (arm (PTuple (PCon "None") (PVar "work")) () (EBlock (DoLet false false (PVar "rows") (EApp (EVar "withEvidencePreserved") (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "runEvalRequestRows") (EApp (EApp (EApp (EVar "forcePrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "work"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "requests"))))) (DoExpr (EApp (EApp (EVar "emitEvalPropRows") (EVar "nonce")) (EVar "rows")))))))) (EMatch (EIf (EVar "exempt") (EVar "None") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (arm (PCon "Some" (PVar "message")) () (EApp (EVar "evalWorkerDie") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "message")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "rows") (EApp (EVar "withEvidencePreserved") (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "runEvalRequestRows") (EApp (EApp (EApp (EApp (EApp (EVar "prepareSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "requests"))))) (DoExpr (EApp (EApp (EVar "emitEvalPropRows") (EVar "nonce")) (EVar "rows"))))))))))
(DTypeSig false "runEvalRequestRows" (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runEvalRequestRows" ((PCon "TestPairErr" (PVar "message")) PWild PWild PWild (PVar "requests")) (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property worker could not prepare properties: ")) (EApp (EVar "display") (EVar "message"))) (ELit (LString "")))))
(DFunDef false "runEvalRequestRows" ((PCon "TestPair" (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "requests")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "requests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "preparedResults") (EApp (EApp (EVar "map") (EApp (EApp (EVar "preparedPlanError") (ELit (LString "eval"))) (EVar "err"))) (EVar "requests")))) (arm (PCon "Ok" (PTuple (PVar "planEnv") (PVar "rows"))) () (EMatch (EApp (EApp (EVar "customPlansReachable") (EVar "planEnv")) (EApp (EVar "preparedPlans") (EVar "rows"))) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPreparedRows") (EVar "planEnv")) (EListLit)) (EVar "rows")) (EVar "tsrc")) (EVar "coreM")) (EVar "modsM"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EVar "runValidatedEvalRequests") (EApp (EApp (EApp (EApp (EApp (EVar "validateHelperPlans") (EVar "planEnv")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EApp (EVar "preparedPlans") (EVar "rows")))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "requests")))))))))
(DTypeSig false "runValidatedEvalRequests" (TyFun (TyCon "HelperValidation") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runValidatedEvalRequests" ((PCon "HelperValidation" (PVar "pair") (PVar "helpers") (PVar "rejected") (PVar "protocol")) (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "requests")) (EMatch (EVar "protocol") (arm (PCon "Some" (PVar "message")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalProtocolRequests") (EVar "pair")) (EVar "message")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "requests"))) (arm (PCon "None") () (EMatch (EVar "pair") (arm (PCon "TestPairErr" (PVar "message")) () (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property helpers could not prepare: ")) (EApp (EVar "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "TestPair" (PVar "_runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "requests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "preparedResults") (EApp (EApp (EVar "map") (EApp (EApp (EVar "preparedPlanError") (ELit (LString "eval"))) (EVar "err"))) (EVar "requests")))) (arm (PCon "Ok" (PTuple (PVar "planEnv") (PVar "rows"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPreparedRows") (EVar "planEnv")) (EVar "helpers")) (EApp (EApp (EApp (EApp (EVar "rejectPreparedHelpers") (EVar "planEnv")) (ELit (LString "eval"))) (EVar "rejected")) (EVar "rows"))) (EVar "tsrc")) (EVar "coreM")) (EVar "modsM")))))))))))
(DTypeSig false "runEvalProtocolRequests" (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runEvalProtocolRequests" ((PCon "TestPairErr" (PVar "message")) PWild PWild PWild PWild (PVar "requests")) (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property helpers could not prepare: ")) (EApp (EVar "display") (EVar "message"))) (ELit (LString "")))))
(DFunDef false "runEvalProtocolRequests" ((PCon "TestPair" (PVar "_runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) (PVar "message") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "requests")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "requests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "preparedResults") (EApp (EApp (EVar "map") (EApp (EApp (EVar "preparedPlanError") (ELit (LString "eval"))) (EVar "err"))) (EVar "requests")))) (arm (PCon "Ok" (PTuple (PVar "planEnv") (PVar "rows"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPreparedRows") (EVar "planEnv")) (EListLit)) (EApp (EApp (EApp (EApp (EVar "rejectPreparedProtocolCustom") (EVar "planEnv")) (ELit (LString "eval"))) (EVar "message")) (EVar "rows"))) (EVar "tsrc")) (EVar "coreM")) (EVar "modsM")))))))
(DTypeSig false "runEvalPreparedRows" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runEvalPreparedRows" ((PVar "env") (PVar "helpers") (PVar "rows") (PVar "tsrc") (PVar "coreM") (PVar "modsM")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPreparedPropRequestsResults") (EVar "env")) (EVar "helpers")) (EVar "rows")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EApp (EApp (EApp (EVar "evalModulesRootEvalEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EBinOp "++" (EVar "coreM") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modsM")))))
(DTypeSig false "propsReportEnginesPlain" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))))))
(DFunDef false "propsReportEnginesPlain" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "propsReportEnginesPlain" ((PCons (PCon "EngInterp") (PVar "rest")) (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runAllPlannedPropRequestsResults") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EVar "index")) (EVar "file")) (ELit (LString "eval"))) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EApp (EApp (EApp (EVar "evalModulesRootEvalEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEnginesPlain") (EVar "rest")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))))
(DFunDef false "propsReportEnginesPlain" ((PCons (PCon "EngNative") (PVar "rest")) (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "runNativePlannedPropRequests") (EVar "target")) (EVar "tsrc")) (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EVar "index")) (EVar "file")) (ELit (LString "native"))) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEnginesPlain") (EVar "rest")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))))
(DTypeSig false "preparedPlans" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyApp (TyCon "List") (TyCon "GenPlan"))))
(DFunDef false "preparedPlans" ((PVar "rows")) (EApp (EApp (EVar "preparedPlansGo") (EVar "rows")) (EListLit)))
(DTypeSig false "preparedPlansGo" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "GenPlan")))))
(DFunDef false "preparedPlansGo" ((PList) (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "preparedPlansGo" ((PCons (PCon "PreparedRun" PWild PWild (PVar "plans")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "preparedPlansGo") (EVar "rest")) (EApp (EApp (EVar "prependPlans") (EVar "plans")) (EVar "acc"))))
(DFunDef false "preparedPlansGo" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "preparedPlansGo") (EVar "rest")) (EVar "acc")))
(DTypeSig false "prependPlans" (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "GenPlan")))))
(DFunDef false "prependPlans" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependPlans" ((PCons (PVar "plan") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "prependPlans") (EVar "rest")) (EBinOp "::" (EVar "plan") (EVar "acc"))))
(DTypeSig false "validateHelperPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "HelperValidation")))))))
(DFunDef false "validateHelperPlans" ((PVar "planEnv") (PVar "runtimeM") (PVar "rawCoreM") (PVar "rawM") (PVar "plans")) (EBlock (DoLet false false (PVar "baseline") (EApp (EVar "helperDiagIndex") (EApp (EApp (EApp (EVar "helperElabDiags") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "validateHelperPlansGo") (EVar "planEnv")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EVar "plans")) (EVar "baseline")) (EVar "omEmpty")))))
(DTypeSig false "validateHelperPlansGo" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "HelperValidation")))))))))
(DFunDef false "validateHelperPlansGo" ((PVar "planEnv") (PVar "runtimeM") (PVar "rawCoreM") (PVar "rawM") (PVar "plans") (PVar "baseline") (PVar "rejected")) (EBlock (DoLet false false (PCon "PropHelpers" (PVar "helpers") (PVar "decls")) (EApp (EApp (EVar "propHelpersForPlans") (EVar "planEnv")) (EVar "plans"))) (DoExpr (EMatch (EVar "helpers") (arm (PList) () (EApp (EApp (EApp (EApp (EVar "HelperValidation") (EApp (EApp (EApp (EApp (EVar "helperPair") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EListLit))) (EListLit)) (EVar "rejected")) (EVar "None"))) (arm PWild () (EBlock (DoLet false false (PVar "candidate") (EApp (EApp (EApp (EApp (EVar "helperPair") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EVar "decls"))) (DoLet false false (PVar "delta") (EApp (EApp (EVar "helperDiagDelta") (EVar "baseline")) (EApp (EApp (EApp (EApp (EVar "helperElabDiagsWith") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EVar "decls")))) (DoLet false false (PVar "helperFiles") (EApp (EApp (EApp (EVar "helperFileIndex") (EVar "helpers")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoLet false false (PTuple (PVar "bad") (PVar "unexpected")) (EApp (EApp (EApp (EApp (EVar "helperDiagFailures") (EVar "helperFiles")) (EVar "delta")) (EVar "omEmpty")) (EVar "False"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omKeys") (EVar "bad")) (EListLit)) (EIf (EVar "unexpected") (EApp (EApp (EApp (EApp (EVar "HelperValidation") (EApp (EApp (EApp (EApp (EVar "helperPair") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EListLit))) (EListLit)) (EVar "rejected")) (EApp (EVar "Some") (ELit (LString "property helper elaboration produced an unattributed diagnostic")))) (EApp (EApp (EApp (EApp (EVar "HelperValidation") (EVar "candidate")) (EVar "helpers")) (EVar "rejected")) (EVar "None"))) (EBlock (DoLet false false (PVar "merged") (EApp (EApp (EVar "mergeHelperFailures") (EVar "rejected")) (EVar "bad"))) (DoLet false false (PVar "kept") (EApp (EApp (EApp (EVar "filterHelperPlans") (EVar "planEnv")) (EVar "merged")) (EVar "plans"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "validateHelperPlansGo") (EVar "planEnv")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EVar "kept")) (EVar "baseline")) (EVar "merged"))))))))))))
(DTypeSig false "helperPair" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TestPair"))))))
(DFunDef false "helperPair" ((PVar "runtimeM") (PVar "rawCoreM") (PVar "rawM") (PVar "decls")) (EBlock (DoLet false false (PVar "injected") (EApp (EApp (EVar "injectIntoLast") (EVar "decls")) (EVar "rawM"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "injected")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild PWild PWild PWild) () (EBlock (DoLet false false (PTuple (PVar "coreM") (PVar "modsM")) (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "TestPair") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "injected")) (EVar "modsM")))))))))
(DTypeSig false "helperElabDiags" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))))
(DFunDef false "helperElabDiags" ((PVar "runtimeM") (PVar "rawCoreM") (PVar "rawM")) (EApp (EApp (EApp (EApp (EVar "helperElabDiagsWith") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EListLit)))
(DTypeSig false "helperElabDiagsWith" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))))
(DFunDef false "helperElabDiagsWith" ((PVar "runtimeM") (PVar "rawCoreM") (PVar "rawM") (PVar "decls")) (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeM")) (EVar "rawCoreM")) (EApp (EApp (EVar "injectIntoLast") (EVar "decls")) (EVar "rawM"))) (arm (PTuple PWild PWild (PVar "perModule") (PVar "residual") PWild PWild) () (EBinOp "++" (EVar "residual") (EApp (EApp (EVar "perModuleErrors") (EVar "perModule")) (EListLit))))))
(DTypeSig false "perModuleErrors" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))
(DFunDef false "perModuleErrors" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "perModuleErrors" ((PCons (PTuple (PVar "mid") (PTuple (PVar "errors") PWild)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "perModuleErrors") (EVar "rest")) (EApp (EApp (EApp (EVar "prependTcRows") (EVar "mid")) (EVar "errors")) (EVar "acc"))))
(DTypeSig false "prependTcRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "TcDiag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))))
(DFunDef false "prependTcRows" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependTcRows" ((PVar "mid") (PCons (PVar "diag") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "prependTcRows") (EVar "mid")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "mid") (EVar "diag")) (EVar "acc"))))
(DTypeSig false "helperDiagIndex" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "helperDiagIndex" ((PList)) (EVar "omEmpty"))
(DFunDef false "helperDiagIndex" ((PCons (PVar "diag") (PVar "rest"))) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "tcDiagGoalKey") (EVar "diag"))) (ELit LUnit)) (EApp (EVar "helperDiagIndex") (EVar "rest"))))
(DTypeSig false "helperDiagDelta" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))
(DFunDef false "helperDiagDelta" (PWild (PList)) (EListLit))
(DFunDef false "helperDiagDelta" ((PVar "baseline") (PCons (PVar "diag") (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "tcDiagGoalKey") (EVar "diag"))) (EVar "baseline")) (EApp (EApp (EVar "helperDiagDelta") (EVar "baseline")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "diag") (EApp (EApp (EVar "helperDiagDelta") (EVar "baseline")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "helperFileIndex" (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))
(DFunDef false "helperFileIndex" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "helperFileIndex" ((PCons (PCon "PropHelper" (PVar "word") PWild PWild) (PVar "rest")) (PVar "i") (PVar "acc")) (EApp (EApp (EApp (EVar "helperFileIndex") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EBinOp "++" (EBinOp "++" (ELit (LString "<property-helper:")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ">")))) (EVar "word")) (EVar "acc"))))
(DTypeSig false "helperDiagFailures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Bool") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Bool")))))))
(DFunDef false "helperDiagFailures" (PWild (PList) (PVar "bad") (PVar "unexpected")) (ETuple (EVar "bad") (EVar "unexpected")))
(DFunDef false "helperDiagFailures" ((PVar "files") (PCons (PTuple PWild (PCon "TcDiag" PWild PWild (PVar "loc") (PVar "message") PWild PWild)) (PVar "rest")) (PVar "bad") (PVar "unexpected")) (EMatch (EVar "loc") (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "file")) (EVar "files")) (arm (PCon "Some" (PVar "word")) () (EApp (EApp (EApp (EApp (EVar "helperDiagFailures") (EVar "files")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "message")) (EVar "bad"))) (EVar "unexpected"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "helperDiagFailures") (EVar "files")) (EVar "rest")) (EVar "bad")) (EVar "True"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "helperDiagFailures") (EVar "files")) (EVar "rest")) (EVar "bad")) (EVar "True")))))
(DTypeSig false "mergeHelperFailures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DFunDef false "mergeHelperFailures" ((PVar "prior") (PVar "next")) (EApp (EApp (EApp (EVar "mergeHelperFailureKeys") (EApp (EVar "omKeys") (EVar "next"))) (EVar "prior")) (EVar "next")))
(DTypeSig false "mergeHelperFailureKeys" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))
(DFunDef false "mergeHelperFailureKeys" ((PList) (PVar "acc") PWild) (EVar "acc"))
(DFunDef false "mergeHelperFailureKeys" ((PCons (PVar "word") (PVar "rest")) (PVar "acc") (PVar "next")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "next")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "mergeHelperFailureKeys") (EVar "rest")) (EVar "acc")) (EVar "next"))) (arm (PCon "Some" (PVar "message")) () (EApp (EApp (EApp (EVar "mergeHelperFailureKeys") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "message")) (EVar "acc"))) (EVar "next")))))
(DTypeSig false "filterHelperPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "GenPlan"))))))
(DFunDef false "filterHelperPlans" ((PVar "env") (PVar "rejected")) (EApp (EVar "filterList") (EApp (EApp (EVar "planHasNoRejectedCarrier") (EVar "env")) (EVar "rejected"))))
(DTypeSig false "planHasNoRejectedCarrier" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "GenPlan") (TyCon "Bool")))))
(DFunDef false "planHasNoRejectedCarrier" ((PVar "env") (PVar "rejected") (PVar "plan")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "customRejected") (EVar "rejected"))) (EApp (EApp (EVar "customPlansReachable") (EVar "env")) (EListLit (EVar "plan"))))))
(DTypeSig false "plansHaveNoRejectedCarrier" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool")))))
(DFunDef false "plansHaveNoRejectedCarrier" ((PVar "env") (PVar "rejected") (PVar "plans")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "customRejected") (EVar "rejected"))) (EApp (EApp (EVar "customPlansReachable") (EVar "env")) (EVar "plans")))))
(DTypeSig false "customRejected" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "CustomPlan") (TyCon "Bool"))))
(DFunDef false "customRejected" ((PVar "rejected") (PCon "CustomPlan" PWild PWild (PVar "word"))) (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "rejected")))
(DTypeSig false "runValidatedPropEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "HelperValidation") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))
(DFunDef false "runValidatedPropEngines" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "runValidatedPropEngines" ((PVar "engines") (PCon "HelperValidation" (PVar "pair") (PVar "helpers") (PVar "rejected") (PVar "protocol")) (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EMatch (EVar "protocol") (arm (PCon "Some" (PVar "message")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProtocolHelperEngines") (EVar "engines")) (EVar "pair")) (EVar "message")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))) (arm (PCon "None") () (EMatch (EVar "pair") (arm (PCon "TestPairErr" (PVar "message")) () (EApp (EApp (EApp (EApp (EApp (EVar "protocolPropResults") (EVar "engines")) (EVar "message")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (arm (PCon "TestPair" (PVar "_runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runValidatedPropEnginesGo") (EVar "engines")) (EVar "helpers")) (EVar "rejected")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index")))))))
(DTypeSig false "runProtocolHelperEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))))
(DFunDef false "runProtocolHelperEngines" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "runProtocolHelperEngines" ((PVar "engines") (PCon "TestPairErr" (PVar "err")) PWild PWild PWild (PVar "userDecls") (PVar "cases") (PVar "filterOpt") PWild PWild) (EApp (EApp (EApp (EApp (EApp (EVar "protocolPropResults") (EVar "engines")) (EVar "err")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")))
(DFunDef false "runProtocolHelperEngines" ((PVar "engines") (PCon "TestPair" (PVar "_runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) (PVar "message") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProtocolHelperEnginesGo") (EVar "engines")) (EVar "message")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index")))
(DTypeSig false "runProtocolHelperEnginesGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))))))
(DFunDef false "runProtocolHelperEnginesGo" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "runProtocolHelperEnginesGo" ((PCons (PVar "engine") (PVar "rest")) (PVar "message") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "engineText") (EApp (EVar "engineName") (EVar "engine"))) (DoLet false false (PVar "requests") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EVar "index")) (EVar "file")) (EVar "engineText")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoLet false false (PVar "next") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProtocolHelperEnginesGo") (EVar "rest")) (EVar "message")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "requests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (EBinOp "++" (EApp (EVar "preparedResults") (EApp (EApp (EVar "map") (EApp (EApp (EVar "preparedPlanError") (EVar "engineText")) (EVar "err"))) (EVar "requests"))) (EVar "next"))) (arm (PCon "Ok" (PTuple (PVar "env") (PVar "prepared"))) () (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EApp (EVar "rejectPreparedProtocolCustom") (EVar "env")) (EVar "engineText")) (EVar "message")) (EVar "prepared"))) (DoLet false false (PVar "here") (EMatch (EVar "engine") (arm (PCon "EngInterp") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPreparedPropRequestsResults") (EVar "env")) (EListLit)) (EVar "rows")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EApp (EApp (EApp (EVar "evalModulesRootEvalEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EBinOp "++" (EVar "coreM") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modsM"))))) (arm (PCon "EngNative") () (EApp (EApp (EApp (EApp (EVar "runPreparedNativeRows") (EVar "rows")) (EVar "target")) (EVar "tsrc")) (EVar "modules"))))) (DoExpr (EBinOp "++" (EVar "here") (EVar "next")))))))))
(DTypeSig false "runValidatedPropEnginesGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))))))))
(DFunDef false "runValidatedPropEnginesGo" ((PList) (PVar "_helpers") (PVar "_rejected") (PVar "_rawCoreM") (PVar "_coreM") (PVar "_rawM") (PVar "_modsM") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PVar "_cases") (PVar "_filterOpt") (PVar "_file") (PVar "_index")) (EListLit))
(DFunDef false "runValidatedPropEnginesGo" ((PCons (PVar "engine") (PVar "rest")) (PVar "helpers") (PVar "rejected") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "engineText") (EApp (EVar "engineName") (EVar "engine"))) (DoLet false false (PVar "requests") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EVar "index")) (EVar "file")) (EVar "engineText")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "requests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (EBinOp "++" (EApp (EVar "preparedResults") (EApp (EApp (EVar "map") (EApp (EApp (EVar "preparedPlanError") (EVar "engineText")) (EVar "err"))) (EVar "requests"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runValidatedPropEnginesGo") (EVar "rest")) (EVar "helpers")) (EVar "rejected")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index")))) (arm (PCon "Ok" (PTuple (PVar "env") (PVar "prepared"))) () (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EApp (EVar "rejectPreparedHelpers") (EVar "env")) (EVar "engineText")) (EVar "rejected")) (EVar "prepared"))) (DoLet false false (PVar "here") (EMatch (EVar "engine") (arm (PCon "EngInterp") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPreparedPropRequestsResults") (EVar "env")) (EVar "helpers")) (EVar "rows")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EApp (EApp (EApp (EVar "evalModulesRootEvalEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EBinOp "++" (EVar "coreM") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modsM"))))) (arm (PCon "EngNative") () (EApp (EApp (EApp (EApp (EVar "runPreparedNativeRows") (EVar "rows")) (EVar "target")) (EVar "tsrc")) (EVar "modules"))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runValidatedPropEnginesGo") (EVar "rest")) (EVar "helpers")) (EVar "rejected")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))))))))))
(DTypeSig false "runPreparedNativeRows" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))
(DFunDef false "runPreparedNativeRows" ((PVar "rows") (PVar "target") (PVar "tsrc") (PVar "modules")) (EApp (EApp (EVar "mergeNativePreparedRows") (EVar "rows")) (EApp (EApp (EApp (EApp (EVar "runNativePlannedPropRequests") (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EApp (EVar "preparedRequests") (EVar "rows")))))
(DTypeSig false "preparedRequests" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyApp (TyCon "List") (TyCon "PropRequest"))))
(DFunDef false "preparedRequests" ((PList)) (EListLit))
(DFunDef false "preparedRequests" ((PCons (PCon "PreparedRun" (PVar "request") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "request") (EApp (EVar "preparedRequests") (EVar "rest"))))
(DFunDef false "preparedRequests" ((PCons PWild (PVar "rest"))) (EApp (EVar "preparedRequests") (EVar "rest")))
(DTypeSig false "preparedResults" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyApp (TyCon "List") (TyCon "PropResult"))))
(DFunDef false "preparedResults" ((PList)) (EListLit))
(DFunDef false "preparedResults" ((PCons (PCon "PreparedResult" (PVar "result")) (PVar "rest"))) (EBinOp "::" (EVar "result") (EApp (EVar "preparedResults") (EVar "rest"))))
(DFunDef false "preparedResults" ((PCons PWild (PVar "rest"))) (EApp (EVar "preparedResults") (EVar "rest")))
(DTypeSig false "mergeNativePreparedRows" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyCon "PropResult")))))
(DFunDef false "mergeNativePreparedRows" ((PList) (PList)) (EListLit))
(DFunDef false "mergeNativePreparedRows" ((PList) (PCons PWild PWild)) (EListLit (EVar "unexpectedNativeProtocolResult")))
(DFunDef false "mergeNativePreparedRows" ((PCons (PCon "PreparedResult" (PVar "result")) (PVar "rest")) (PVar "native")) (EBinOp "::" (EApp (EApp (EVar "propResultForEngine") (ELit (LString "native"))) (EVar "result")) (EApp (EApp (EVar "mergeNativePreparedRows") (EVar "rest")) (EVar "native"))))
(DFunDef false "mergeNativePreparedRows" ((PCons (PCon "PreparedRun" (PVar "request") PWild PWild) (PVar "rest")) (PList)) (EBinOp "::" (EApp (EVar "nativeProtocolResult") (EVar "request")) (EApp (EApp (EVar "mergeNativePreparedRows") (EVar "rest")) (EListLit))))
(DFunDef false "mergeNativePreparedRows" ((PCons (PCon "PreparedRun" PWild PWild PWild) (PVar "rest")) (PCons (PVar "native") (PVar "nativeRest"))) (EBinOp "::" (EVar "native") (EApp (EApp (EVar "mergeNativePreparedRows") (EVar "rest")) (EVar "nativeRest"))))
(DTypeSig false "preparedPlanError" (TyFun (TyCon "String") (TyFun (TyCon "PlanError") (TyFun (TyCon "PropRequest") (TyCon "PreparedPropRequest")))))
(DFunDef false "preparedPlanError" ((PVar "engine") (PVar "err") (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropCapabilityError"))) (EApp (EVar "planErrorText") (EVar "err"))) (EVar "seed")) (EVar "cases"))))
(DTypeSig false "rejectPreparedHelpers" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyApp (TyCon "List") (TyCon "PreparedPropRequest")))))))
(DFunDef false "rejectPreparedHelpers" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "rejectPreparedHelpers" ((PVar "env") (PVar "engine") (PVar "rejected") (PCons (PAs "row" (PCon "PreparedResult" PWild)) (PVar "rest"))) (EBinOp "::" (EVar "row") (EApp (EApp (EApp (EApp (EVar "rejectPreparedHelpers") (EVar "env")) (EVar "engine")) (EVar "rejected")) (EVar "rest"))))
(DFunDef false "rejectPreparedHelpers" ((PVar "env") (PVar "engine") (PVar "rejected") (PCons (PAs "row" (PCon "PreparedRun" (PVar "request") PWild (PVar "plans"))) (PVar "rest"))) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EApp (EApp (EVar "rejectPreparedHelpers") (EVar "env")) (EVar "engine")) (EVar "rejected")) (EVar "rest"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "plansHaveNoRejectedCarrier") (EVar "env")) (EVar "rejected")) (EVar "plans")) (EBinOp "::" (EVar "row") (EVar "next")) (EBinOp "::" (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EApp (EApp (EVar "helperCapabilityResult") (EVar "env")) (EVar "engine")) (EVar "request")) (EVar "rejected")) (EVar "plans"))) (EVar "next"))))))
(DTypeSig false "rejectPreparedProtocolCustom" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyApp (TyCon "List") (TyCon "PreparedPropRequest")))))))
(DFunDef false "rejectPreparedProtocolCustom" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "rejectPreparedProtocolCustom" ((PVar "env") (PVar "engine") (PVar "message") (PCons (PAs "row" (PCon "PreparedResult" PWild)) (PVar "rest"))) (EBinOp "::" (EVar "row") (EApp (EApp (EApp (EApp (EVar "rejectPreparedProtocolCustom") (EVar "env")) (EVar "engine")) (EVar "message")) (EVar "rest"))))
(DFunDef false "rejectPreparedProtocolCustom" ((PVar "env") (PVar "engine") (PVar "message") (PCons (PAs "row" (PCon "PreparedRun" (PVar "request") PWild (PVar "plans"))) (PVar "rest"))) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EApp (EApp (EVar "rejectPreparedProtocolCustom") (EVar "env")) (EVar "engine")) (EVar "message")) (EVar "rest"))) (DoExpr (EMatch (EApp (EApp (EVar "customPlansReachable") (EVar "env")) (EVar "plans")) (arm (PList) () (EBinOp "::" (EVar "row") (EVar "next"))) (arm PWild () (EBinOp "::" (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EVar "helperProtocolResult") (EVar "engine")) (EVar "message")) (EVar "request"))) (EVar "next")))))))
(DTypeSig false "helperProtocolResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyCon "PropResult")))))
(DFunDef false "helperProtocolResult" ((PVar "engine") (PVar "message") (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EVar "message")) (EVar "seed")) (EVar "cases")))
(DTypeSig false "helperCapabilityResult" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "PropResult")))))))
(DFunDef false "helperCapabilityResult" ((PVar "env") (PVar "engine") (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases")) (PVar "rejected") (PVar "plans")) (EMatch (EApp (EApp (EVar "firstRejectedCarrier") (EVar "rejected")) (EApp (EApp (EVar "customPlansReachable") (EVar "env")) (EVar "plans"))) (arm (PCon "Some" (PCon "CustomPlan" PWild (PVar "carrier") (PVar "word"))) () (EBlock (DoLet false false (PVar "detail") (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "rejected")) (arm (PCon "Some" (PVar "message")) () (EVar "message")) (arm (PCon "None") () (ELit (LString "typed helper could not be elaborated"))))) (DoLet false false (PVar "err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "name")) (ELit (LString "$property-helper"))) (EVar "carrier")) (EVar "PEUnusableArbitrary")) (EVar "detail"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropCapabilityError"))) (EApp (EVar "planErrorText") (EVar "err"))) (EVar "seed")) (EVar "cases"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "property helper rejection lost its carrier"))) (EVar "seed")) (EVar "cases")))))
(DTypeSig false "firstRejectedCarrier" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyApp (TyCon "Option") (TyCon "CustomPlan")))))
(DFunDef false "firstRejectedCarrier" (PWild (PList)) (EVar "None"))
(DFunDef false "firstRejectedCarrier" ((PVar "rejected") (PCons (PAs "custom" (PCon "CustomPlan" PWild PWild (PVar "word"))) (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "rejected")) (EApp (EVar "Some") (EVar "custom")) (EIf (EVar "otherwise") (EApp (EApp (EVar "firstRejectedCarrier") (EVar "rejected")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nativeProtocolResult" (TyFun (TyCon "PropRequest") (TyCon "PropResult")))
(DFunDef false "nativeProtocolResult" ((PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "native property runner returned no selected result"))) (EVar "seed")) (EVar "cases")))
(DTypeSig false "unexpectedNativeProtocolResult" (TyCon "PropResult"))
(DFunDef false "unexpectedNativeProtocolResult" () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (ELit (LString "<native property runner>"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "native property runner returned an unexpected selected result"))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "propResultForEngine" (TyFun (TyCon "String") (TyFun (TyCon "PropResult") (TyCon "PropResult"))))
(DFunDef false "propResultForEngine" ((PVar "engine") (PCon "PropResult" PWild (PVar "name") (PVar "status") (PVar "kind") (PVar "detail") (PVar "seed") (PVar "cases"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "status")) (EVar "kind")) (EVar "detail")) (EVar "seed")) (EVar "cases")))
(DTypeSig false "protocolPropResults" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PropResult"))))))))
(DFunDef false "protocolPropResults" ((PList) PWild PWild PWild PWild) (EListLit))
(DFunDef false "protocolPropResults" ((PCons (PVar "engine") (PVar "rest")) (PVar "message") (PVar "userDecls") (PVar "cases") (PVar "filterOpt")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "protocolPropsForEngine") (EApp (EVar "engineName") (EVar "engine"))) (EVar "message")) (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "userDecls")))) (EVar "cases")) (EApp (EApp (EApp (EApp (EApp (EVar "protocolPropResults") (EVar "rest")) (EVar "message")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))))
(DTypeSig false "protocolPropsForEngine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "PropResult")))))))
(DFunDef false "protocolPropsForEngine" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "protocolPropsForEngine" ((PVar "engine") (PVar "message") (PCons (PCon "DProp" PWild (PVar "name") PWild PWild) (PVar "rest")) (PVar "cases")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EVar "message")) (EApp (EVar "propSeedValue") (ELit LUnit))) (EVar "cases")) (EApp (EApp (EApp (EApp (EVar "protocolPropsForEngine") (EVar "engine")) (EVar "message")) (EVar "rest")) (EVar "cases"))))
(DFunDef false "protocolPropsForEngine" ((PVar "engine") (PVar "message") (PCons PWild (PVar "rest")) (PVar "cases")) (EApp (EApp (EApp (EApp (EVar "protocolPropsForEngine") (EVar "engine")) (EVar "message")) (EVar "rest")) (EVar "cases")))
(DTypeSig false "planModules" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "PlanModule")))))))
(DFunDef false "planModules" ((PVar "rawCore") (PVar "coreM") (PVar "rawModules") (PVar "runtimeModules")) (EBinOp "::" (EApp (EApp (EApp (EVar "PlanModule") (ELit (LString "core"))) (EVar "rawCore")) (EVar "coreM")) (EApp (EApp (EVar "planModulesGo") (EVar "rawModules")) (EVar "runtimeModules"))))
(DTypeSig false "planModulesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "PlanModule")))))
(DFunDef false "planModulesGo" ((PList) (PList)) (EListLit))
(DFunDef false "planModulesGo" ((PCons (PTuple (PVar "_rawId") (PVar "rawDecls")) (PVar "rawRest")) (PCons (PTuple (PVar "runtimeId") (PVar "runtimeDecls")) (PVar "runtimeRest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "PlanModule") (EVar "runtimeId")) (EVar "rawDecls")) (EVar "runtimeDecls")) (EApp (EApp (EVar "planModulesGo") (EVar "rawRest")) (EVar "runtimeRest"))))
(DFunDef false "planModulesGo" (PWild PWild) (EListLit))
(DTypeSig false "rootPlanModuleId" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "rootPlanModuleId" ((PList) (PVar "fallback")) (EVar "fallback"))
(DFunDef false "rootPlanModuleId" ((PList (PTuple (PVar "moduleId") PWild)) PWild) (EVar "moduleId"))
(DFunDef false "rootPlanModuleId" ((PCons PWild (PVar "rest")) (PVar "fallback")) (EApp (EApp (EVar "rootPlanModuleId") (EVar "rest")) (EVar "fallback")))
(DTypeSig false "propRequestsFor" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PropRequest")))))))))
(DFunDef false "propRequestsFor" ((PVar "index") (PVar "file") (PVar "engine") (PVar "userDecls") (PVar "cases") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsForGo") (EVar "index")) (EVar "file")) (EVar "engine")) (EApp (EVar "propSeedValue") (ELit LUnit))) (EVar "cases")) (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "userDecls")))))
(DTypeSig false "propRequestsForGo" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "PropRequest")))))))))
(DFunDef false "propRequestsForGo" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "propRequestsForGo" ((PVar "index") (PVar "file") (PVar "engine") (PVar "seed") (PVar "cases") (PCons (PCon "DProp" PWild (PVar "name") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "request") (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "pinFromIndex") (EVar "index")) (EVar "file")) (EVar "PropPin")) (EVar "name")) (EVar "engine")) (arm (PCon "Some" (PVar "pin")) () (EApp (EApp (EApp (EVar "PropRequest") (EVar "name")) (EApp (EApp (EVar "pinSeedOr") (EVar "seed")) (EVar "pin"))) (EApp (EApp (EVar "pinCasesOr") (EVar "cases")) (EVar "pin")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "PropRequest") (EVar "name")) (EVar "seed")) (EVar "cases"))))) (DoExpr (EBinOp "::" (EVar "request") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsForGo") (EVar "index")) (EVar "file")) (EVar "engine")) (EVar "seed")) (EVar "cases")) (EVar "rest"))))))
(DFunDef false "propRequestsForGo" ((PVar "index") (PVar "file") (PVar "engine") (PVar "seed") (PVar "cases") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsForGo") (EVar "index")) (EVar "file")) (EVar "engine")) (EVar "seed")) (EVar "cases")) (EVar "rest")))
(DTypeSig false "pinSeedOr" (TyFun (TyCon "Int") (TyFun (TyCon "TestPin") (TyCon "Int"))))
(DFunDef false "pinSeedOr" ((PVar "fallback") (PVar "pin")) (EMatch (EFieldAccess (EVar "pin") "pinSeed") (arm (PCon "Some" (PVar "seed")) () (EVar "seed")) (arm (PCon "None") () (EVar "fallback"))))
(DTypeSig false "pinCasesOr" (TyFun (TyCon "Int") (TyFun (TyCon "TestPin") (TyCon "Int"))))
(DFunDef false "pinCasesOr" ((PVar "fallback") (PVar "pin")) (EMatch (EFieldAccess (EVar "pin") "pinCases") (arm (PCon "Some" (PVar "cases")) () (EVar "cases")) (arm (PCon "None") () (EVar "fallback"))))
(DTypeSig false "testDeclsReportPinned" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))))
(DFunDef false "testDeclsReportPinned" ((PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt") (PVar "file") (PVar "index")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportEngines") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EVar "index")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "testDeclsReportEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))))
(DFunDef false "testDeclsReportEngines" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "testDeclsReportEngines" ((PCons (PVar "e") (PVar "rest")) (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "tagWithEngine") (EVar "e")) (EVar "t")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportOn") (EVar "e")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportEngines") (EVar "rest")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EVar "index"))))
(DTypeSig false "tagWithEngine" (TyFun (TyCon "Engine") (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")) (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))
(DFunDef false "tagWithEngine" ((PVar "e") (PTuple (PVar "name") (PVar "line") (PVar "result"))) (ETuple (EVar "e") (EVar "name") (EVar "line") (EVar "result")))
(DTypeSig false "testDeclsReportOn" (TyFun (TyCon "Engine") (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))))
(DFunDef false "testDeclsReportOn" ((PCon "EngInterp") (PCon "TestPairErr" PWild) (PVar "_runtimeDecls") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PVar "_filterOpt") (PVar "_file") (PVar "_index")) (EListLit))
(DFunDef false "testDeclsReportOn" ((PCon "EngInterp") (PCon "TestPair" (PVar "_runtimeM") (PVar "_rawCoreM") (PVar "coreM") (PVar "_rawM") (PVar "modsM")) (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt") (PVar "_file") (PVar "_index")) (EApp (EApp (EApp (EApp (EVar "gatedTestsCollect") (EVar "target")) (EBinOp "++" (EBinOp "++" (EVar "runtimeDecls") (EVar "coreM")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modsM")))) (EApp (EApp (EApp (EVar "evalModulesRootEvalEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EApp (EApp (EApp (EApp (EVar "rootTestsOf") (EVar "filterOpt")) (EVar "tsrc")) (EVar "modsM")) (EVar "userDecls"))))
(DFunDef false "testDeclsReportOn" ((PCon "EngNative") (PVar "_pair") (PVar "_runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "_userDecls") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "tests") (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EVar "nativeRawTests") (EVar "tsrc")))) (DoLet false false (PVar "ordinary") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "notExpectedNativeError") (EVar "index")) (EVar "file"))) (EVar "tests"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestsWithPinnedErrors") (EVar "target")) (EVar "tsrc")) (EVar "index")) (EVar "file")) (EVar "tests")) (EApp (EApp (EApp (EVar "runNativeTests") (EVar "target")) (EVar "tsrc")) (EVar "ordinary"))))))
(DTypeSig false "notExpectedNativeError" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")) (TyCon "Bool")))))
(DFunDef false "notExpectedNativeError" ((PVar "index") (PVar "file") (PTuple (PVar "name") PWild PWild)) (EApp (EVar "not") (EApp (EApp (EApp (EVar "isExpectedNativeError") (EVar "index")) (EVar "file")) (EVar "name"))))
(DTypeSig false "isExpectedNativeError" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isExpectedNativeError" ((PVar "index") (PVar "file") (PVar "name")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "pinFromIndex") (EVar "index")) (EVar "file")) (EVar "TestPin")) (EVar "name")) (ELit (LString "native"))) (arm (PCon "Some" (PVar "pin")) () (EMatch (EFieldAccess (EVar "pin") "pinExpected") (arm (PCon "Some" (PCon "ExpectError" PWild)) () (EVar "True")) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "nativeTestsWithPinnedErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "ExResult")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))))))
(DFunDef false "nativeTestsWithPinnedErrors" (PWild PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "nativeTestsWithPinnedErrors" ((PVar "target") (PVar "tsrc") (PVar "index") (PVar "file") (PCons (PAs "selected" (PTuple (PVar "name") (PVar "line") PWild)) (PVar "rest")) (PVar "ordinary")) (EIf (EApp (EApp (EApp (EVar "isExpectedNativeError") (EVar "index")) (EVar "file")) (EVar "name")) (EMatch (EApp (EApp (EApp (EVar "runNativeTests") (EVar "target")) (EVar "tsrc")) (EListLit (EVar "selected"))) (arm (PList (PVar "result")) () (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EVar "result")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestsWithPinnedErrors") (EVar "target")) (EVar "tsrc")) (EVar "index")) (EVar "file")) (EVar "rest")) (EVar "ordinary")))) (arm PWild () (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EApp (EVar "Errored") (ELit (LString "native test runner returned no selected result")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestsWithPinnedErrors") (EVar "target")) (EVar "tsrc")) (EVar "index")) (EVar "file")) (EVar "rest")) (EVar "ordinary"))))) (EMatch (EVar "ordinary") (arm (PList) () (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EApp (EVar "Errored") (ELit (LString "native test runner returned no selected result")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestsWithPinnedErrors") (EVar "target")) (EVar "tsrc")) (EVar "index")) (EVar "file")) (EVar "rest")) (EListLit)))) (arm (PCons (PVar "result") (PVar "ordinaryRest")) () (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EVar "result")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestsWithPinnedErrors") (EVar "target")) (EVar "tsrc")) (EVar "index")) (EVar "file")) (EVar "rest")) (EVar "ordinaryRest")))))))
(DTypeSig false "gatedTestsCollect" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))))
(DFunDef false "gatedTestsCollect" ((PVar "target") (PVar "corpus") (PVar "env") (PVar "tests")) (EMatch (EApp (EApp (EApp (EVar "uncapableExternsEnv") (EVar "corpus")) (EVar "env")) (EVar "tests")) (arm (PList) () (EApp (EApp (EVar "runTestsCollectEnv") (EVar "env")) (EVar "tests"))) (arm (PVar "names") () (EBlock (DoLet false false (PVar "msg") (EApp (EApp (EVar "uncapableExternsMsg") (EVar "target")) (EVar "names"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "t")) (ETuple (EApp (EVar "fst3") (EVar "t")) (EApp (EVar "snd3") (EVar "t")) (EApp (EVar "Errored") (EVar "msg"))))) (EVar "tests")))))))
(DTypeSig false "snd3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "b")))
(DFunDef false "snd3" ((PTuple PWild (PVar "b") PWild)) (EVar "b"))
(DTypeSig false "runTestsCollectEnv" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))
(DFunDef false "runTestsCollectEnv" (PWild (PList)) (EListLit))
(DFunDef false "runTestsCollectEnv" ((PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EApp (EApp (EVar "runOneTestEnv") (EVar "env")) (EVar "body"))) (EApp (EApp (EVar "runTestsCollectEnv") (EVar "env")) (EVar "rest"))))
(DTypeSig true "testHelpText" (TyCon "String"))
(DFunDef false "testHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka test — Run doctests + property tests\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka test [--native | --engines eval,native] [--json] [--filter <substring>]\n")) (ELit (LString "              [--seed <n>] [--cases <n>] [file.mdk | dir]\n")) (ELit (LString "\n")) (ELit (LString "  --native            run doctests, properties and `test \"…\"` decls through a\n")) (ELit (LString "                      compiled native binary (the default; shorthand\n")) (ELit (LString "                      for --engines native)\n")) (ELit (LString "  --engines e1,e2,...  run the listed engine set (known: eval, native);\n")) (ELit (LString "                      exit code is the AND across engines. `eval` is\n")) (ELit (LString "                      the interpreter; property tests follow this selection\n")) (ELit (LString "  --json               emit a {\"file\":...,\"engine\":...,\"doctests\":...,\n")) (ELit (LString "                      \"properties\":...,\"tests\":...,\"summary\":...} JSON\n")) (ELit (LString "                      object instead of human text (single file.mdk target\n")) (ELit (LString "                      only; agrees with the human report's pass/fail counts\n")) (ELit (LString "                      on all three phases)\n")) (ELit (LString "  --filter <substring> restrict to doctests/`test \"…\"`/`prop \"…\"` whose\n")) (ELit (LString "                      name (or, for a doctest, input expression) contains\n")) (ELit (LString "                      <substring>\n")) (ELit (LString "  --seed <n>           seed the property-test RNG (printed on every prop\n")) (ELit (LString "                      failure so the counterexample is replayable); never\n")) (ELit (LString "                      affects a program under test's own random draws\n")) (ELit (LString "  --cases <n>           run each property with <n> generated cases\n")) (ELit (LString "                      instead of the default 100\n")) (ELit (LString "\n")) (ELit (LString "--native and --engines are mutually exclusive. With neither, the default\n")) (ELit (LString "is the native backend alone.\n")) (ELit (LString "\n")) (ELit (LString "With no target, tests the project containing the current directory: the\n")) (ELit (LString "nearest directory at or above it with a medaka.toml, walked like a dir\n")) (ELit (LString "target. Outside any project, pass a file.mdk or dir target.\n")))))
(DTypeSig true "testArgSpec" (TyCon "ArgSpec"))
(DFunDef false "testArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "test"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--native")))) (ELit (LString "shorthand for --engines native"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--engines")))) (ELit (LString "eval,native"))) (ELit (LString "engines to run each example under"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--filter")))) (ELit (LString "SUBSTRING"))) (ELit (LString "run only matching examples"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--seed")))) (ELit (LString "N"))) (ELit (LString "seed the property RNG"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--cases")))) (ELit (LString "N"))) (ELit (LString "property cases per test"))) (EApp (EVar "internal") (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--props-worker")))) (ELit (LString "INTERNAL: run isolated interpreter properties"))))))))
(DTypeSig true "parseTestIntFlag" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "parseTestIntFlag" ((PVar "nm") (PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (EVar "nm")) (EVar "a")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Some" (PVar "s")) () (EMatch (EApp (EVar "toInt") (EVar "s")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "n")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "nm"))) (ELit (LString " requires an integer value, got '"))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "'")))))))))
(DTypeSig true "parseTestCasesFlag" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "parseTestCasesFlag" ((PVar "a")) (EMatch (EApp (EApp (EVar "parseTestIntFlag") (ELit (LString "--cases"))) (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PCon "None")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Ok" (PCon "Some" (PVar "n"))) () (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--cases requires a positive integer value, got '")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "'")))) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "n")))))))
(DTypeSig true "parseTestEngines" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseTestEngines" ((PVar "a")) (EMatch (ETuple (EApp (EApp (EVar "flagValue") (ELit (LString "--engines"))) (EVar "a")) (EApp (EApp (EVar "flag") (ELit (LString "--native"))) (EVar "a"))) (arm (PTuple (PCon "Some" PWild) (PCon "True")) () (EApp (EVar "Err") (ELit (LString "--native and --engines are mutually exclusive; --native is shorthand for --engines native")))) (arm (PTuple (PCon "Some" (PVar "spec")) (PCon "False")) () (EApp (EVar "parseEngineList") (EVar "spec"))) (arm (PTuple (PCon "None") (PCon "True")) () (EApp (EVar "Ok") (EListLit (EVar "EngNative")))) (arm (PTuple (PCon "None") (PCon "False")) () (EApp (EVar "Ok") (EListLit (EVar "EngNative"))))))
(DTypeSig false "parseEngineList" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseEngineList" ((PVar "spec")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EApp (EVar "map") (EVar "stringTrim")) (EApp (EVar "splitLintNames") (EVar "spec"))))) (DoExpr (EMatch (EVar "names") (arm (PList) () (EApp (EVar "Err") (ELit (LString "--engines requires at least one of: eval, native")))) (arm PWild () (EApp (EVar "parseEngineNames") (EVar "names")))))))
(DTypeSig false "parseEngineNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseEngineNames" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "parseEngineNames" ((PCons (PVar "n") (PVar "rest"))) (EMatch (EApp (EVar "engineOfName") (EVar "n")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown engine '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' (known: eval, native)"))))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "e") (EVar "_s")))) (EApp (EVar "parseEngineNames") (EVar "rest"))))))
(DTypeSig false "engineOfName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Engine"))))
(DFunDef false "engineOfName" ((PLit (LString "eval"))) (EApp (EVar "Some") (EVar "EngInterp")))
(DFunDef false "engineOfName" ((PLit (LString "native"))) (EApp (EVar "Some") (EVar "EngNative")))
(DFunDef false "engineOfName" (PWild) (EVar "None"))
(DTypeSig true "runTestOne" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "runTestOne" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "target")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "target")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig true "cliTestReportOk" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool"))))))
(DFunDef false "cliTestReportOk" ((PVar "typeError") (PVar "runs") (PVar "props") (PVar "tests")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNone") (EVar "typeError")) (EApp (EVar "cliAllDoctestRunsOk") (EVar "runs"))) (EApp (EVar "cliAllPropsPass") (EVar "props"))) (EApp (EVar "cliAllTestsPass") (EVar "tests"))))
(DTypeSig false "cliAllDoctestRunsOk" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyCon "Bool")))
(DFunDef false "cliAllDoctestRunsOk" ((PList)) (EVar "True"))
(DFunDef false "cliAllDoctestRunsOk" ((PCons (PTuple PWild (PVar "run")) (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "runFailed") (EVar "run")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "runErrors") (EVar "run")) (ELit (LInt 0)))) (EApp (EVar "cliAllDoctestRunsOk") (EVar "rest"))))
(DTypeSig false "cliAllPropsPass" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Bool")))
(DFunDef false "cliAllPropsPass" ((PList)) (EVar "True"))
(DFunDef false "cliAllPropsPass" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "propResultPassed") (EVar "p")) (EApp (EVar "cliAllPropsPass") (EVar "rest"))))
(DTypeSig false "cliAllTestsPass" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))
(DFunDef false "cliAllTestsPass" ((PList)) (EVar "True"))
(DFunDef false "cliAllTestsPass" ((PCons (PTuple PWild PWild PWild (PCon "Pass" PWild PWild)) (PVar "rest"))) (EApp (EVar "cliAllTestsPass") (EVar "rest")))
(DFunDef false "cliAllTestsPass" ((PCons PWild PWild)) (EVar "False"))
(DTypeSig false "cliPrimaryDoctestRun" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyCon "RunResult")))
(DFunDef false "cliPrimaryDoctestRun" ((PList)) (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DFunDef false "cliPrimaryDoctestRun" ((PCons (PTuple PWild (PVar "run")) PWild)) (EVar "run"))
(DTypeSig false "cliCountPassProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "cliCountPassProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountPassProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "cliCountPassProps") (EVar "rest"))))
(DTypeSig false "cliCountFailProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "cliCountFailProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountFailProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "cliCountFailProps") (EVar "rest"))))
(DTypeSig false "cliCountPassTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Int")))
(DFunDef false "cliCountPassTests" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountPassTests" ((PCons (PTuple PWild PWild PWild (PCon "Pass" PWild PWild)) (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "cliCountPassTests") (EVar "rest"))))
(DFunDef false "cliCountPassTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "cliCountPassTests") (EVar "rest")))
(DTypeSig false "cliCountFailTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Int")))
(DFunDef false "cliCountFailTests" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountFailTests" ((PCons (PTuple PWild PWild PWild (PCon "Pass" PWild PWild)) (PVar "rest"))) (EApp (EVar "cliCountFailTests") (EVar "rest")))
(DFunDef false "cliCountFailTests" ((PCons PWild (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "cliCountFailTests") (EVar "rest"))))
(DTypeSig false "cliExampleJson" (TyFun (TyTuple (TyCon "Example") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "cliExampleJson" ((PTuple (PVar "ex") (PVar "res"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EApp (EVar "exampleLine") (EVar "ex")))) (ETuple (ELit (LString "input")) (EApp (EVar "JString") (EApp (EVar "exampleInput") (EVar "ex"))))) (EApp (EVar "exResultJsonFields") (EVar "res")))))
(DTypeSig false "cliDoctestsJson" (TyFun (TyCon "RunResult") (TyCon "Json")))
(DFunDef false "cliDoctestsJson" ((PVar "run")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "total")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "run")) (EApp (EVar "runFailed") (EVar "run"))) (EApp (EVar "runErrors") (EVar "run"))))) (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EApp (EVar "runPassed") (EVar "run")))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EApp (EVar "runFailed") (EVar "run")))) (ETuple (ELit (LString "errors")) (EApp (EVar "JInt") (EApp (EVar "runErrors") (EVar "run")))) (ETuple (ELit (LString "examples")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "cliExampleJson")) (EApp (EVar "runDetails") (EVar "run"))))))))
(DTypeSig false "cliPropJson" (TyFun (TyCon "PropResult") (TyCon "Json")))
(DFunDef false "cliPropJson" () (EVar "propResultJson"))
(DTypeSig false "cliTestJson" (TyFun (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "cliTestJson" ((PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "result"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "engineName") (EVar "engine"))))) (EApp (EVar "exResultJsonFields") (EVar "result")))))
(DTypeSig false "cliTypeErrorField" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliTypeErrorField" ((PCon "None")) (EListLit))
(DFunDef false "cliTypeErrorField" ((PCon "Some" (PVar "errText"))) (EListLit (ETuple (ELit (LString "typeError")) (EApp (EVar "JString") (EVar "errText")))))
(DTypeSig false "cliTypecheckSkippedField" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliTypecheckSkippedField" ((PCon "False")) (EListLit))
(DFunDef false "cliTypecheckSkippedField" ((PCon "True")) (EListLit (ETuple (ELit (LString "typecheckSkipped")) (EApp (EVar "JBool") (EVar "True")))))
(DTypeSig false "cliDoctestRunEngineNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "Engine"))))
(DFunDef false "cliDoctestRunEngineNames" ((PList)) (EListLit))
(DFunDef false "cliDoctestRunEngineNames" ((PCons (PTuple (PVar "e") PWild) (PVar "rest"))) (EBinOp "::" (EVar "e") (EApp (EVar "cliDoctestRunEngineNames") (EVar "rest"))))
(DTypeSig false "cliPrimaryEngineName" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "String")))
(DFunDef false "cliPrimaryEngineName" ((PList)) (ELit (LString "unknown")))
(DFunDef false "cliPrimaryEngineName" ((PCons (PVar "e") PWild)) (EApp (EVar "engineName") (EVar "e")))
(DTypeSig true "cliTestReportJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyFun (TyCon "Bool") (TyCon "Json")))))))))
(DFunDef false "cliTestReportJson" ((PVar "path") (PVar "typeError") (PVar "engines") (PVar "runs") (PVar "props") (PVar "tests") (PVar "typecheckSkipped")) (EBlock (DoLet false false (PVar "runEngines") (EIf (EApp (EVar "isNone") (EVar "typeError")) (EApp (EVar "cliDoctestRunEngineNames") (EVar "runs")) (EVar "engines"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "cliPrimaryEngineName") (EVar "runEngines"))))) (EApp (EVar "cliTypeErrorField") (EVar "typeError"))) (EApp (EVar "cliTypecheckSkippedField") (EVar "typecheckSkipped"))) (EListLit (ETuple (ELit (LString "doctests")) (EApp (EVar "cliDoctestsJson") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "cliPropJson")) (EVar "props")))) (ETuple (ELit (LString "tests")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "cliTestJson")) (EVar "tests")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "cliCountPassProps") (EVar "props"))) (EApp (EVar "cliCountPassTests") (EVar "tests"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "runErrors") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (EApp (EVar "cliCountFailProps") (EVar "props"))) (EApp (EVar "cliCountFailTests") (EVar "tests"))))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EApp (EApp (EVar "cliTestReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")) (EVar "tests")))))))))))))
(DTypeSig true "cliGradedTestReportOk" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Bool"))))))
(DFunDef false "cliGradedTestReportOk" ((PVar "reportError") (PVar "runs") (PVar "props") (PVar "tests")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNone") (EVar "reportError")) (EApp (EVar "cliAllDoctestRunsOk") (EVar "runs"))) (EApp (EVar "allGradedPropsPass") (EVar "props"))) (EApp (EVar "allGradedTestsPass") (EVar "tests"))))
(DTypeSig false "allGradedPropsPass" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Bool")))
(DFunDef false "allGradedPropsPass" ((PList)) (EVar "True"))
(DFunDef false "allGradedPropsPass" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "gradedPropPassed") (EVar "row")) (EApp (EVar "allGradedPropsPass") (EVar "rest"))))
(DTypeSig false "allGradedTestsPass" (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Bool")))
(DFunDef false "allGradedTestsPass" ((PList)) (EVar "True"))
(DFunDef false "allGradedTestsPass" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "gradedTestPassed") (EVar "row")) (EApp (EVar "allGradedTestsPass") (EVar "rest"))))
(DTypeSig false "cliGradedPropJson" (TyFun (TyCon "GradedProp") (TyCon "Json")))
(DFunDef false "cliGradedPropJson" ((PVar "row")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "gradedPropRaw") (EVar "row"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "propResultEngine") (EVar "raw")))) (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "propResultName") (EVar "raw")))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EApp (EVar "gradedPropStatus") (EVar "row")))) (ETuple (ELit (LString "rawStatus")) (EApp (EVar "JString") (EApp (EVar "gradedPropRawStatus") (EVar "row")))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EApp (EVar "propResultDetail") (EVar "raw")))) (ETuple (ELit (LString "failureKind")) (EApp (EVar "propFailureKindJson") (EApp (EVar "propResultFailureKind") (EVar "raw")))) (ETuple (ELit (LString "seed")) (EApp (EVar "JInt") (EApp (EVar "propResultSeed") (EVar "raw")))) (ETuple (ELit (LString "cases")) (EApp (EVar "JInt") (EApp (EVar "propResultCases") (EVar "raw"))))) (EApp (EVar "cliIssueField") (EApp (EVar "gradedPropIssue") (EVar "row")))) (EApp (EVar "cliPinField") (EApp (EVar "gradedPropPinDetail") (EVar "row"))))))))
(DTypeSig false "cliGradedTestJson" (TyFun (TyCon "GradedTest") (TyCon "Json")))
(DFunDef false "cliGradedTestJson" ((PVar "row")) (EBlock (DoLet false false (PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "raw")) (EApp (EVar "gradedTestRaw") (EVar "row"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EVar "engine"))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EApp (EVar "gradedTestStatus") (EVar "row")))) (ETuple (ELit (LString "rawStatus")) (EApp (EVar "JString") (EApp (EVar "gradedTestRawStatus") (EVar "row"))))) (EApp (EVar "cliRawTestOperands") (EVar "raw"))) (EApp (EVar "cliIssueField") (EApp (EVar "gradedTestIssue") (EVar "row")))) (EApp (EVar "cliPinField") (EApp (EVar "gradedTestPinDetail") (EVar "row"))))))))
(DTypeSig false "cliRawTestOperands" (TyFun (TyCon "ExResult") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliRawTestOperands" ((PCon "Pass" (PVar "expected") (PVar "actual"))) (EListLit (ETuple (ELit (LString "expected")) (EApp (EVar "JString") (EVar "expected"))) (ETuple (ELit (LString "actual")) (EApp (EVar "JString") (EVar "actual")))))
(DFunDef false "cliRawTestOperands" ((PCon "Fail" (PVar "detail") (PVar "expected") (PVar "actual"))) (EBinOp "++" (EListLit (ETuple (ELit (LString "expected")) (EApp (EVar "JString") (EVar "expected"))) (ETuple (ELit (LString "actual")) (EApp (EVar "JString") (EVar "actual")))) (EIf (EBinOp "==" (EVar "detail") (ELit (LString ""))) (EListLit) (EListLit (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail")))))))
(DFunDef false "cliRawTestOperands" ((PCon "Errored" (PVar "detail"))) (EListLit (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail")))))
(DTypeSig false "cliIssueField" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliIssueField" ((PCon "None")) (EListLit))
(DFunDef false "cliIssueField" ((PCon "Some" (PVar "issue"))) (EListLit (ETuple (ELit (LString "issue")) (EApp (EVar "JInt") (EVar "issue")))))
(DTypeSig false "cliPinField" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliPinField" ((PCon "None")) (EListLit))
(DFunDef false "cliPinField" ((PCon "Some" (PVar "detail"))) (EListLit (ETuple (ELit (LString "pin")) (EApp (EVar "JString") (EVar "detail")))))
(DTypeSig false "cliCountPassedGradedProps" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Int")))
(DFunDef false "cliCountPassedGradedProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountPassedGradedProps" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "&&" (EApp (EVar "propResultPassed") (EApp (EVar "gradedPropRaw") (EVar "row"))) (EApp (EVar "gradedPropPassed") (EVar "row"))) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "cliCountPassedGradedProps") (EVar "rest"))))
(DTypeSig false "cliCountFailedGradedProps" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Int")))
(DFunDef false "cliCountFailedGradedProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountFailedGradedProps" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "gradedPropPassed") (EVar "row")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "cliCountFailedGradedProps") (EVar "rest"))))
(DTypeSig false "cliCountPassedGradedTests" (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Int")))
(DFunDef false "cliCountPassedGradedTests" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountPassedGradedTests" ((PCons (PVar "row") (PVar "rest"))) (EBlock (DoLet false false (PTuple PWild PWild PWild (PVar "raw")) (EApp (EVar "gradedTestRaw") (EVar "row"))) (DoExpr (EBinOp "+" (EIf (EBinOp "&&" (EApp (EVar "rawTestPassed") (EVar "raw")) (EApp (EVar "gradedTestPassed") (EVar "row"))) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "cliCountPassedGradedTests") (EVar "rest"))))))
(DTypeSig false "rawTestPassed" (TyFun (TyCon "ExResult") (TyCon "Bool")))
(DFunDef false "rawTestPassed" ((PCon "Pass" PWild PWild)) (EVar "True"))
(DFunDef false "rawTestPassed" (PWild) (EVar "False"))
(DTypeSig false "cliCountFailedGradedTests" (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Int")))
(DFunDef false "cliCountFailedGradedTests" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountFailedGradedTests" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "gradedTestPassed") (EVar "row")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "cliCountFailedGradedTests") (EVar "rest"))))
(DTypeSig true "cliGradedTestReportJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyFun (TyCon "Bool") (TyCon "Json")))))))))
(DFunDef false "cliGradedTestReportJson" ((PVar "path") (PVar "reportError") (PVar "engines") (PVar "runs") (PVar "props") (PVar "tests") (PVar "typecheckSkipped")) (EBlock (DoLet false false (PVar "runEngines") (EIf (EApp (EVar "isNone") (EVar "reportError")) (EApp (EVar "cliDoctestRunEngineNames") (EVar "runs")) (EVar "engines"))) (DoLet false false (PVar "known") (EBinOp "+" (EApp (EVar "knownRedCountProps") (EVar "props")) (EApp (EVar "knownRedCountTests") (EVar "tests")))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "cliPrimaryEngineName") (EVar "runEngines"))))) (EApp (EVar "cliTypeErrorField") (EVar "reportError"))) (EApp (EVar "cliTypecheckSkippedField") (EVar "typecheckSkipped"))) (EListLit (ETuple (ELit (LString "doctests")) (EApp (EVar "cliDoctestsJson") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "cliGradedPropJson")) (EVar "props")))) (ETuple (ELit (LString "tests")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "cliGradedTestJson")) (EVar "tests")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "cliCountPassedGradedProps") (EVar "props"))) (EApp (EVar "cliCountPassedGradedTests") (EVar "tests"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "runErrors") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (EApp (EVar "cliCountFailedGradedProps") (EVar "props"))) (EApp (EVar "cliCountFailedGradedTests") (EVar "tests"))))) (ETuple (ELit (LString "knownRed")) (EApp (EVar "JInt") (EVar "known"))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EApp (EApp (EVar "cliGradedTestReportOk") (EVar "reportError")) (EVar "runs")) (EVar "props")) (EVar "tests")))))))))))))
(DTypeSig true "checkTestMdkRoster" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "checkTestMdkRoster" ((PVar "root") (PVar "targets") (PVar "files")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "git"))) (EBinOp "++" (EListLit (ELit (LString "ls-files")) (ELit (LString "--full-name")) (ELit (LString "--"))) (EVar "targets"))) (arm (PCon "Err" PWild) () (EVar "True")) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "tracked") (EApp (EApp (EVar "filterList") (EApp (EVar "endsWith") (ELit (LString "_test.mdk")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitNl") (EVar "out"))))) (DoLet false false (PVar "relFiles") (EApp (EApp (EVar "map") (EApp (EVar "stripRootPrefix") (EVar "root"))) (EVar "files"))) (DoLet false false (PVar "missing") (EApp (EApp (EVar "filterList") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "t")) (EVar "relFiles"))))) (EVar "tracked"))) (DoExpr (EMatch (EVar "missing") (arm (PList) () (EVar "True")) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: git-tracked but not discovered: ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "missing")))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))) (arm (PCon "Ok" (PTuple PWild PWild PWild)) () (EVar "True"))))
(DTypeSig false "stripRootPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripRootPrefix" ((PVar "root") (PVar "p")) (EBlock (DoLet false false (PVar "prefix") (EBinOp "++" (EVar "root") (ELit (LString "/")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "p")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "p"))) (EVar "p")) (EVar "p")))))
(DTypeSig false "testChildArgs" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "testChildArgs" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "seedOpt") (PVar "f")) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "test")) (EVar "f") (ELit (LString "--engines")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "engineName")) (EVar "engines"))) (ELit (LString "--cases")) (EApp (EVar "intToString") (EVar "cases"))) (EMatch (EVar "filterOpt") (arm (PCon "Some" (PVar "s")) () (EListLit (ELit (LString "--filter")) (EVar "s"))) (arm (PCon "None") () (EListLit)))) (EMatch (EVar "seedOpt") (arm (PCon "Some" (PVar "s")) () (EListLit (ELit (LString "--seed")) (EApp (EVar "intToString") (EVar "s")))) (arm (PCon "None") () (EListLit)))))
(DTypeSig true "testFilesGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))))))
(DFunDef false "testFilesGo" (PWild PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "testFilesGo" ((PVar "engines") (PVar "rtPath") (PVar "corePath") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "seedOpt") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EVar "executablePath") (ELit LUnit)))) (DoLet false false (PVar "args") (EApp (EApp (EApp (EApp (EApp (EVar "testChildArgs") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EVar "f"))) (DoLet false false (PVar "ok") (EMatch (EApp (EApp (EVar "runCommand") (EVar "medaka")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EVar "display") (EVar "f"))) (ELit (LString ": failed to start test runner: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "out"))) (DoLet false false PWild (EApp (EVar "flushStdout") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EVar "True") (EBlock (DoLet false false PWild (EApp (EVar "ePutStr") (EVar "err"))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EVar "display") (EVar "f"))) (ELit (LString ": DEAD (child exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))))) (DoExpr (EVar "False"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EApp (EVar "not") (EVar "ok")))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" false) (mem "Loc" true) (mem "Ty" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseResult" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "desugaredPreludeKey" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgramFilesLocatedE" false) (mem "modIdToPath" false) (mem "loadErrorMessage" false) (mem "LoadError" true) (mem "entrySearchRoots" false) (mem "canonicalPathId" false) (mem "readDeps" false) (mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false) (mem "readSource" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "readPreludeFile" false) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateOne" false) (mem "elaborateModules" false) (mem "TcDiag" true) (mem "tcDiagGoalKey" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "withEvidencePreserved" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "mangleCtorCollisionsPair" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" false) (mem "EvalEnv" false) (mem "evalOneRootEnvWith" false) (mem "evalModulesRootEvalEnvWith" false) (mem "evalModulesRootEnvWith" false) (mem "currentEvalFile" false) (mem "modulePathMap" false) (mem "testCapableExterns" false) (mem "funNamesOf" false) (mem "dropShadowedExp" false) (mem "lookupBinding" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" true) (mem "Engine" true) (mem "engineName" false) (mem "extractExamples" false) (mem "buildSynthResults" false) (mem "buildSynthDecls" false) (mem "buildDetailsFrom" false) (mem "doctestFailSuffix" false) (mem "hasUseDecls" false) (mem "printDoctestDetails" false) (mem "runDetails" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "synthName" false) (mem "exResultJsonFields" false))))
(DUse false (UseGroup ("tools" "native_doctest") ((mem "runNativeDoctests" false))))
(DUse false (UseGroup ("tools" "native_test_decls") ((mem "runNativeTests" false))))
(DUse false (UseGroup ("tools" "native_props") ((mem "runNativePlannedPropRequests" false))))
(DUse false (UseGroup ("tools" "prop_plan") ((mem "PlanModule" true) (mem "CustomPlan" true) (mem "GenPlan" false) (mem "PlanEnv" false) (mem "PlanError" true) (mem "PlanErrorReason" true) (mem "customPlansReachable" false) (mem "planErrorText" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "hasProps" false) (mem "runAllPlannedPropRequestsResults" false) (mem "preparePlannedPropRequests" false) (mem "runPreparedPropRequestsResults" false) (mem "PreparedPropRequest" true) (mem "PropHelper" true) (mem "PropResult" true) (mem "PropStatus" true) (mem "PropFailureKind" true) (mem "PropRequest" true) (mem "filterProps" false) (mem "filterPropsByName" false) (mem "propResultName" false) (mem "propResultPassed" false) (mem "propResultDetail" false) (mem "propResultEngine" false) (mem "propResultStatus" false) (mem "propResultSeed" false) (mem "propResultCases" false) (mem "propResultFailureKind" false) (mem "propSeedValue" false))))
(DUse false (UseGroup ("tools" "prop_helpers") ((mem "PropHelpers" true) (mem "propHelpersForPlans" false))))
(DUse false (UseGroup ("tools" "eval_props") ((mem "emitEvalPropRows" false) (mem "decodeEvalPropRows" false) (mem "propResultJson" false) (mem "propFailureKindJson" false) (mem "startEvalPropWorker" false) (mem "takeEvalPropBootstrap" false))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "firstNonEmptyLine" false))))
(DUse false (UseGroup ("tools" "test_pins") ((mem "PinIndex" false) (mem "PinKind" true) (mem "TestExpectedFailure" true) (mem "TestPin" false) (mem "buildPinIndex" false) (mem "pinFromIndex" false) (mem "validatePinNames" false))))
(DUse false (UseGroup ("tools" "test_pins_io") ((mem "loadPinContext" false))))
(DUse false (UseGroup ("tools" "test_pins_report") ((mem "GradedProp" false) (mem "GradedTest" false) (mem "gradeProps" false) (mem "gradeTests" false) (mem "gradedPropPassed" false) (mem "gradedTestPassed" false) (mem "gradedPropRaw" false) (mem "gradedTestRaw" false) (mem "gradedPropVerdict" false) (mem "gradedTestVerdict" false) (mem "knownRedCountProps" false) (mem "knownRedCountTests" false) (mem "gradedPropStatus" false) (mem "gradedPropRawStatus" false) (mem "gradedPropIssue" false) (mem "gradedPropPinDetail" false) (mem "gradedTestStatus" false) (mem "gradedTestRawStatus" false) (mem "gradedTestIssue" false) (mem "gradedTestPinDetail" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("tools" "test_runner") ((mem "collectTests" false) (mem "exprLine" false) (mem "runOneTestEnv" false) (mem "hasTests" false) (mem "uncapableExternsEnv" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeLocated" false) (mem "projectDiagsFromTc" false) (mem "projectDiagsLoaded" false) (mem "noStdlibExports" false) (mem "chainKeyOf" false) (mem "desugaredModPairs" false) (mem "mkDiag" false) (mem "Severity" true) (mem "readDiagSrc" false) (mem "ppDiagCliSrc" false) (mem "ppDiagCliLines" false) (mem "srcLinesArr" false) (mem "parseErrDiag" false) (mem "Diag" false) (mem "diagIsError" false))))
(DUse true (UseGroup ("support" "util") ((mem "rootsOrDefault" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "joinNl" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "endsWith" false) (mem "splitOnChar" false) (mem "contains" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "stringTrim" false) (mem "reverseL" false) (mem "anyList" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "baseOf" false) (mem "joinPath" false))))
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "Args" false) (mem "spec" false) (mem "switch" false) (mem "value" false) (mem "internal" false) (mem "flag" false) (mem "flagValue" false) (mem "withStrictDash" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "splitLintNames" false))))
(DUse false (UseGroup ("string") ((mem "toInt" false))))
(DTypeSig false "substringMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substringMatch" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "runTest" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTest" ((PVar "engines") (PVar "runtimeP") (PVar "coreP") (PVar "target") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EMatch (EApp (EVar "readPreludeFile") (EVar "runtimeP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "coreP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EVar "parseErrDiag") (EVar "target")) (EVar "e"))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "exemptNotice") (EVar "exempt")) (EVar "target")) (EVar "userDecls"))) (DoExpr (EMatch (EApp (EApp (EVar "pinIndexForTarget") (EVar "target")) (EVar "userDecls")) (arm (PCon "Err" (PVar "err")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "err"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PTuple (PVar "file") (PVar "index"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveAll") (EVar "engines")) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")) (EVar "exempt")) (EVar "file")) (EMethodRef "index")))))))))))))))
(DTypeSig false "pinIndexForTarget" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "PinIndex")))))))
(DFunDef false "pinIndexForTarget" ((PVar "target") (PVar "userDecls")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "loadPinContext") (EVar "target"))) (ELam ((PVar "context")) (ELet false (PVar "names") (EApp (EApp (EApp (EApp (EVar "validatePinNames") (EFieldAccess (EVar "context") "contextPins")) (EFieldAccess (EVar "context") "contextFile")) (EApp (EVar "propNamesOf") (EVar "userDecls"))) (EApp (EVar "testNamesOf") (EVar "userDecls"))) (EMatch (EVar "names") (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EVar "err"))) (arm (PCon "Ok" (PLit LUnit)) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "index")) (ETuple (EFieldAccess (EVar "context") "contextFile") (EMethodRef "index")))) (EApp (EVar "buildPinIndex") (EFieldAccess (EVar "context") "contextPins")))))))))
(DTypeSig false "typecheckExempt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "typecheckExempt" ((PVar "target") (PVar "userDecls") (PVar "tsrc")) (EIf (EApp (EVar "isNonEmptyL") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (EVar "False") (EIf (EApp (EVar "isNewVehiclePath") (EVar "target")) (EVar "False") (EIf (EVar "otherwise") (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EApp (EVar "hasTests") (EVar "userDecls"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isNewVehiclePath" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "isNewVehiclePath" ((PVar "target")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "target")) (EBlock (DoLet false false (PVar "canon") (EApp (EVar "canonicalizePath") (EVar "target"))) (DoExpr (EBinOp "||" (EBinOp "||" (EApp (EVar "hasVehicleSegment") (EVar "canon")) (EApp (EVar "underProjectTestDir") (EVar "canon"))) (EApp (EVar "underMedakaRepoTestDir") (EVar "canon"))))) (EVar "False")))
(DTypeSig false "hasVehicleSegment" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasVehicleSegment" ((PVar "path")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (ELam ((PVar "seg")) (EBinOp "||" (EBinOp "==" (EVar "seg") (ELit (LString "compiler"))) (EBinOp "==" (EVar "seg") (ELit (LString "stdlib")))))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path")))))
(DTypeSig false "underProjectTestDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "underProjectTestDir" ((PVar "target")) (EBlock (DoLet false false (PVar "d") (EApp (EVar "dirOf") (EVar "target"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "baseOf") (EVar "d")) (ELit (LString "test"))) (EMatch (EApp (EVar "findProjectRoot") (EVar "d")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))) (EVar "False")))))
(DTypeSig false "underMedakaRepoTestDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "underMedakaRepoTestDir" ((PVar "target")) (EBlock (DoLet false false (PVar "d") (EApp (EVar "dirOf") (EVar "target"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "baseOf") (EVar "d")) (ELit (LString "test"))) (EApp (EVar "fileExists") (EApp (EApp (EVar "joinPath") (EApp (EVar "dirOf") (EVar "d"))) (ELit (LString "compiler/medaka.toml"))))))))
(DTypeSig false "exemptNotice" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "exemptNotice" ((PCon "False") PWild PWild) (ELit LUnit))
(DFunDef false "exemptNotice" ((PCon "True") (PVar "target") (PVar "userDecls")) (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckSkipNotice") (EVar "target")) (EVar "userDecls"))))
(DTypeSig false "singleFileTypeErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "singleFileTypeErrors" ((PVar "target") (PVar "tsrc") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EApp (EApp (EApp (EApp (EVar "analyzeLocated") (EVar "noStdlibExports")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs")))))))))
(DTypeSig false "gateOfPerModule" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "gateOfPerModule" ((PCon "True") PWild PWild PWild PWild) (EVar "None"))
(DFunDef false "gateOfPerModule" ((PCon "False") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "mods") (PVar "perModule")) (EApp (EVar "renderGate") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDiagsFromTc") (EVar "noStdlibExports")) (EVar "True")) (EListLit)) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "mods")) (EVar "perModule"))))
(DTypeSig false "loadGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "loadGate" ((PCon "True") PWild PWild) (EVar "None"))
(DFunDef false "loadGate" ((PCon "False") (PVar "target") (PVar "le")) (EApp (EVar "renderGate") (EApp (EApp (EVar "loadErrorDiags") (EVar "target")) (EVar "le"))))
(DTypeSig false "loadErrorDiags" (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "loadErrorDiags" (PWild (PCon "LoadParseFailed" (PVar "mpath") PWild (PVar "pe"))) (EListLit (ETuple (EVar "mpath") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "mpath")) (EVar "pe"))))))
(DFunDef false "loadErrorDiags" ((PVar "target") (PCon "LoadCycle" (PVar "e") (PVar "cpath") (PVar "csite"))) (EMatch (EVar "csite") (arm (PCon "Some" (PTuple PWild (PVar "loc"))) () (EListLit (ETuple (EVar "cpath") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "e")) (EApp (EVar "Some") (EVar "loc"))))))) (arm (PCon "None") () (EListLit (ETuple (EVar "target") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "e")) (EVar "None"))))))))
(DFunDef false "loadErrorDiags" ((PVar "target") (PCon "LoadMsg" (PVar "e"))) (EListLit (ETuple (EVar "target") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "e")) (EVar "None"))))))
(DTypeSig false "renderGate" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "renderGate" ((PVar "results")) (EMatch (EApp (EApp (EDictApp "flatMap") (EVar "renderFileErrors")) (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EVar "results"))) (arm (PList) () (EVar "None")) (arm (PVar "rendered") () (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "rendered"))))))
(DTypeSig false "renderFileErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderFileErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EVar "diags"))))
(DTypeSig false "typecheckGateFail" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typecheckGateFail" ((PVar "target") (PVar "errText")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type error in ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString " — `medaka test` requires it to `medaka check` first:\n"))) (EApp (EMethodRef "display") (EVar "errText"))) (ELit (LString ""))))
(DTypeSig false "typecheckSkipNotice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "typecheckSkipNotice" ((PVar "target") (PVar "userDecls")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "note: typechecking was skipped for ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "\n  reason: the module declares "))) (EApp (EMethodRef "display") (EApp (EVar "skipReasonDecls") (EVar "userDecls")))) (ELit (LString " and no doctests, so `medaka test` exempts it from the type checker (issue #1229) — those phases exist to exercise eval on constructs `medaka check` rejects.\n  a runtime error below may therefore be an uncaught TYPE error.\n  to type-check it: medaka check "))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ""))))
(DTypeSig false "skipReasonDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "skipReasonDecls" ((PVar "userDecls")) (EIf (EBinOp "&&" (EApp (EVar "hasTests") (EVar "userDecls")) (EApp (EVar "hasProps") (EVar "userDecls"))) (ELit (LString "`test \"…\"` and `prop \"…\"` decls")) (EIf (EApp (EVar "hasTests") (EVar "userDecls")) (ELit (LString "`test \"…\"` decls")) (EIf (EVar "otherwise") (ELit (LString "`prop \"…\"` decls")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "filterMatchedNothing" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))))
(DFunDef false "filterMatchedNothing" ((PCon "None") PWild PWild) (EVar "False"))
(DFunDef false "filterMatchedNothing" ((PCon "Some" (PVar "sub")) (PVar "tsrc") (PVar "userDecls")) (EApp (EVar "not") (EBinOp "||" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterExamplesByName") (EApp (EVar "Some") (EMethodRef "sub"))) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterPropsByName") (EApp (EVar "Some") (EMethodRef "sub"))) (EApp (EVar "filterProps") (EVar "userDecls"))))) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterTestsByName") (EApp (EVar "Some") (EMethodRef "sub"))) (EApp (EVar "nativeRawTests") (EVar "tsrc")))))))
(DData Private "TestPair" () ((variant "TestPair" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))) (variant "TestPairErr" (ConPos (TyCon "String")))) ())
(DData Private "HelperValidation" () ((variant "HelperValidation" (ConPos (TyCon "TestPair") (TyApp (TyCon "List") (TyCon "PropHelper")) (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))) ())
(DData Private "DoctestTrees" () ((variant "DtPair" (ConPos (TyCon "TestPair"))) (variant "DtSingle" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DData Private "Prepared" () ((variant "PreparedPair" (ConPos (TyCon "TestPair"))) (variant "PreparedInject" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DTypeSig false "prepareMulti" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Prepared")))))))))))
(DFunDef false "prepareMulti" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "exempt") (PVar "hasDoctests") (PVar "synthDecls")) (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "le")) () (ETuple (EApp (EApp (EApp (EVar "loadGate") (EVar "exempt")) (EVar "target")) (EVar "le")) (EApp (EVar "PreparedPair") (EApp (EVar "TestPairErr") (EApp (EVar "loadErrorMessage") (EVar "le")))))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "modulePathMap")) (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EVar "mods")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "elaborateFor") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "mods")) (EVar "exempt")) (EVar "hasDoctests")) (EVar "synthDecls")))))))
(DTypeSig false "elaborateFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Prepared"))))))))))))
(DFunDef false "elaborateFor" ((PVar "rsrc") (PVar "csrc") (PVar "_target") (PVar "_roots") (PVar "mods") (PVar "exempt") (PCon "False") PWild) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (DoLet false false (PVar "rawModules") (EApp (EVar "desugaredModPairs") (EVar "mods"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "rawModules")) (arm (PTuple (PVar "coreE") (PVar "modulesE") (PVar "perModule") PWild PWild PWild) () (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "gateOfPerModule") (EVar "exempt")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "mods")) (EVar "perModule")) (EApp (EVar "PreparedPair") (EApp (EApp (EApp (EApp (EVar "uncurryPair") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "rawModules")) (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE")))))))))))
(DFunDef false "elaborateFor" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "mods") (PVar "exempt") (PCon "True") (PVar "synthDecls")) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "gateOfCheck") (EVar "exempt")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "mods")) (EApp (EApp (EVar "PreparedInject") (EVar "mods")) (EVar "synthDecls"))))
(DTypeSig false "forcePrepared" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Prepared") (TyEffect ("IO") None (TyCon "TestPair"))))))
(DFunDef false "forcePrepared" (PWild PWild (PCon "PreparedPair" (PVar "pair"))) (EVar "pair"))
(DFunDef false "forcePrepared" ((PVar "rsrc") (PVar "csrc") (PCon "PreparedInject" (PVar "mods") (PVar "synthDecls"))) (EBlock (DoLet false false (PVar "injected") (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EApp (EVar "desugaredModPairs") (EVar "mods")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "injected")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild PWild PWild PWild) () (EApp (EApp (EApp (EApp (EVar "uncurryPair") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "injected")) (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE")))))))))
(DTypeSig false "gateOfCheck" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "gateOfCheck" ((PCon "True") PWild PWild PWild PWild PWild) (EVar "None"))
(DFunDef false "gateOfCheck" ((PCon "False") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "mods")) (EApp (EVar "renderGate") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDiagsLoaded") (EVar "noStdlibExports")) (EVar "True")) (EListLit)) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EApp (EVar "Some") (ETuple (EApp (EVar "desugaredPreludeKey") (EVar "rsrc")) (EApp (EVar "desugaredPreludeKey") (EVar "csrc"))))) (EApp (EApp (EVar "chainKeyOf") (EVar "target")) (EVar "roots"))) (EVar "mods"))))
(DTypeSig false "uncurryPair" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyCon "TestPair"))))))
(DFunDef false "uncurryPair" ((PVar "runtimeDecls") (PVar "rawCore") (PVar "rawModules") (PTuple (PVar "core") (PVar "mods"))) (EApp (EApp (EApp (EApp (EApp (EVar "TestPair") (EVar "runtimeDecls")) (EVar "rawCore")) (EVar "core")) (EVar "rawModules")) (EVar "mods")))
(DTypeSig false "prepareSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "TestPair"))))))))
(DFunDef false "prepareSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "roots") (PVar "userDecls")) (EBlock (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "modulePathMap")) (EListLit (ETuple (EVar "rootId") (EVar "target"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "uncurryPair") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls")))) (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))))))
(DTypeSig false "driveAll" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyCon "Bool")))))))))))))))))
(DFunDef false "driveAll" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls") (PVar "exempt") (PVar "file") (PVar "index")) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveMulti") (EVar "engines")) (EVar "runtimeDecls")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")) (EVar "exempt")) (EVar "file")) (EMethodRef "index")) (EIf (EVar "otherwise") (EMatch (EIf (EVar "exempt") (EVar "None") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "rsrc")) (EVar "csrc"))) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "errText")))) (DoExpr (EVar "False")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveSingle") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")) (EVar "file")) (EMethodRef "index")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "driveMulti" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyCon "Bool"))))))))))))))))
(DFunDef false "driveMulti" ((PVar "engines") (PVar "runtimeDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls") (PVar "exempt") (PVar "file") (PVar "index")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoLet false false (PVar "allExamples") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EVar "allExamples"))) (DoLet false false (PVar "synthResults") (EApp (EApp (EVar "buildSynthResults") (EVar "userDecls")) (EVar "examples"))) (DoLet false false (PVar "synthDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults"))) (DoLet false false (PVar "gated") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prepareMulti") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "exempt")) (EApp (EVar "isNonEmptyL") (EVar "allExamples"))) (EVar "synthDecls"))) (DoExpr (EMatch (EVar "gated") (arm (PTuple (PCon "Some" (PVar "errText")) PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "errText")))) (DoExpr (EVar "False")))) (arm (PTuple (PCon "None") (PVar "prepared")) () (EIf (EApp (EApp (EApp (EVar "filterMatchedNothing") (EVar "filterOpt")) (EVar "tsrc")) (EVar "userDecls")) (EBlock (DoLet false false PWild (EApp (EVar "filterMatchedNothingNotice") (EVar "target"))) (DoExpr (EVar "False"))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EVar "forcePrepared") (EVar "rsrc")) (EVar "csrc")) (EVar "prepared"))) (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "engines")) (EApp (EVar "DtPair") (EVar "pair"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropsPinned") (EVar "engines")) (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsPinned") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk"))))))))))
(DTypeSig false "driveSingle" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyCon "Bool"))))))))))))))
(DFunDef false "driveSingle" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls") (PVar "file") (PVar "index")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoExpr (EIf (EApp (EApp (EApp (EVar "filterMatchedNothing") (EVar "filterOpt")) (EVar "tsrc")) (EVar "userDecls")) (EBlock (DoLet false false PWild (EApp (EVar "filterMatchedNothingNotice") (EVar "target"))) (DoExpr (EVar "False"))) (EBlock (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "engines")) (EApp (EApp (EApp (EApp (EApp (EVar "DtSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EApp (EApp (EVar "buildSynthResults") (EVar "userDecls")) (EVar "examples")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EApp (EVar "hasTests") (EVar "userDecls"))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EApp (EApp (EVar "prepareSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropsPinned") (EVar "engines")) (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsPinned") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk")))) (EVar "doctestsOk"))))))))
(DTypeSig false "filterMatchedNothingNotice" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "filterMatchedNothingNotice" ((PVar "target")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": --filter matched no doctests, props, or `test \"…\"` decls")))))
(DTypeSig false "filterExamplesByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyCon "Example")))))
(DFunDef false "filterExamplesByName" ((PCon "None") (PVar "examples")) (EVar "examples"))
(DFunDef false "filterExamplesByName" ((PCon "Some" (PVar "sub")) (PVar "examples")) (EApp (EApp (EVar "filterList") (ELam ((PVar "ex")) (EApp (EApp (EVar "substringMatch") (EMethodRef "sub")) (EApp (EVar "exampleInput") (EVar "ex"))))) (EVar "examples")))
(DTypeSig false "runDoctests" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runDoctests" ((PVar "engines") (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running doctests in ")) (EVar "target")))) (DoExpr (EMatch (EVar "examples") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  (no doctests found)")))) (DoExpr (EVar "True")))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEngines") (EVar "engines")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))))))
(DTypeSig false "runEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runEngines" ((PList (PVar "e")) (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EVar "reportDoctests") (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))))
(DFunDef false "runEngines" ((PVar "engines") (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEnginesTagged") (EVar "engines")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))
(DTypeSig false "runEnginesTagged" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runEnginesTagged" ((PList) PWild PWild PWild PWild PWild PWild) (EVar "True"))
(DFunDef false "runEnginesTagged" ((PCons (PVar "e") (PVar "rest")) (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "-- ")) (EApp (EMethodRef "display") (EApp (EVar "engineName") (EVar "e")))) (ELit (LString " --"))))) (DoLet false false (PVar "ok") (EApp (EApp (EVar "reportDoctests") (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))) (DoLet false false (PVar "restOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEnginesTagged") (EVar "rest")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (DoExpr (EBinOp "&&" (EVar "ok") (EVar "restOk")))))
(DTypeSig true "runChosenOn" (TyFun (TyCon "Engine") (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult"))))))))))
(DFunDef false "runChosenOn" ((PCon "EngInterp") (PVar "trees") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EVar "runChosen") (EVar "trees")) (EVar "examples")) (EVar "synthResults")))
(DFunDef false "runChosenOn" ((PCon "EngNative") (PVar "_trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EVar "runNativeDoctests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))
(DTypeSig false "runChosen" (TyFun (TyCon "DoctestTrees") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult"))))))
(DFunDef false "runChosen" ((PCon "DtPair" (PCon "TestPairErr" (PVar "e"))) (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Err") (EVar "e"))) (EVar "synthResults")) (EVar "examples")))
(DFunDef false "runChosen" ((PCon "DtPair" (PCon "TestPair" (PVar "_runtimeM") (PVar "_rawCoreM") (PVar "coreM") (PVar "_rawM") (PVar "modsM"))) (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "synthResults")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))
(DFunDef false "runChosen" ((PCon "DtSingle" (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "roots") (PVar "userDecls")) (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "allUser") (EBinOp "++" (EVar "userDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults")))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EApp (EVar "funNamesOf") (EVar "allUser"))) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "modulePathMap")) (EListLit (ETuple (ELit (LString "__main__")) (EVar "target"))))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateOne") (EVar "runtimeDecls")) (EVar "livePrelude")) (ETuple (EVar "rootId") (EVar "allUser")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalOneRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EListLit)) (ETuple (ELit (LString "__main__")) (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "synthResults")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))
(DTypeSig false "renderExamples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "renderExamples" ((PVar "env") (PVar "synthResults") (PVar "examples")) (EApp (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (EVar "synthResults")) (ELit (LInt 0))) (EVar "examples")))
(DTypeSig false "renderExamplesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))))
(DFunDef false "renderExamplesGo" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "renderExamplesGo" ((PVar "env") (PCons (PVar "sr") (PVar "srRest")) (PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "renderOneExample") (EVar "env")) (EVar "sr")) (EVar "i")) (EVar "ex")) (EApp (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (EVar "srRest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DFunDef false "renderExamplesGo" ((PVar "env") (PList) (PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "renderOneExample") (EVar "env")) (EApp (EVar "Err") (ELit (LString "")))) (EVar "i")) (EVar "ex")) (EApp (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (EListLit)) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "renderOneExample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "renderOneExample" ((PVar "env") (PVar "sr") (PVar "i") (PVar "ex")) (EMatch (EApp (EApp (EVar "lookupBinding") (EApp (EVar "synthName") (EVar "i"))) (EVar "env")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "could not evaluate: ")) (EApp (EVar "exampleInput") (EVar "ex"))))) (arm (PCon "Some" (PVar "v")) () (EMatch (EApp (EApp (EVar "firstUnresolvedDottedRef") (EVar "env")) (EVar "sr")) (arm (PCon "Some" (PVar "name")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "could not evaluate: ")) (EApp (EMethodRef "display") (EApp (EVar "exampleInput") (EVar "ex")))) (ELit (LString " (unresolved: "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ")"))))) (arm (PCon "None") () (EApp (EVar "Ok") (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))))))))
(DTypeSig false "firstUnresolvedDottedRef" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "firstUnresolvedDottedRef" (PWild (PCon "Err" PWild)) (EVar "None"))
(DFunDef false "firstUnresolvedDottedRef" ((PVar "env") (PCon "Ok" (PVar "ds"))) (EApp (EApp (EVar "firstUnresolvedName") (EVar "env")) (EApp (EApp (EDictApp "flatMap") (EVar "declRefs")) (EVar "ds"))))
(DTypeSig false "firstUnresolvedName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "firstUnresolvedName" (PWild (PList)) (EVar "None"))
(DFunDef false "firstUnresolvedName" ((PVar "env") (PCons (PVar "n") (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EVar "isDottedRef") (EVar "n")) (EApp (EVar "isNone") (EApp (EApp (EVar "lookupBinding") (EVar "n")) (EVar "env")))) (EApp (EVar "Some") (EVar "n")) (EIf (EVar "otherwise") (EApp (EApp (EVar "firstUnresolvedName") (EVar "env")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isDottedRef" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDottedRef" ((PVar "n")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (ELit (LString "."))) (EVar "n"))))
(DTypeSig true "singleRootId" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "singleRootId" ((PVar "roots") (PVar "target")) (EBlock (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "target"))))) (DoExpr (EApp (EApp (EApp (EVar "canonicalPathId") (EVar "deps")) (EVar "roots")) (EVar "target")))))
(DTypeSig false "programIsCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "programIsCore" ((PVar "prog")) (EBinOp "&&" (EApp (EVar "pcHasOrdering") (EVar "prog")) (EApp (EVar "pcHasFoldable") (EVar "prog"))))
(DTypeSig false "pcHasOrdering" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "pcHasOrdering" ((PList)) (EVar "False"))
(DFunDef false "pcHasOrdering" ((PCons (PRec "DData" ((rf "dataName" (PLit (LString "Ordering")))) false) PWild)) (EVar "True"))
(DFunDef false "pcHasOrdering" ((PCons PWild (PVar "rest"))) (EApp (EVar "pcHasOrdering") (EVar "rest")))
(DTypeSig false "pcHasFoldable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "pcHasFoldable" ((PList)) (EVar "False"))
(DFunDef false "pcHasFoldable" ((PCons (PRec "DInterface" ((rf "name" (PLit (LString "Foldable")))) true) PWild)) (EVar "True"))
(DFunDef false "pcHasFoldable" ((PCons PWild (PVar "rest"))) (EApp (EVar "pcHasFoldable") (EVar "rest")))
(DTypeSig false "injectIntoLast" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "injectIntoLast" (PWild (PList)) (EListLit))
(DFunDef false "injectIntoLast" ((PVar "synthDecls") (PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EBinOp "++" (EVar "decls") (EVar "synthDecls")))))
(DFunDef false "injectIntoLast" ((PVar "synthDecls") (PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EVar "rest"))))
(DTypeSig false "reportDoctests" (TyFun (TyCon "String") (TyFun (TyCon "RunResult") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "reportDoctests" ((PVar "target") (PVar "result")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "printDoctestDetails") (EVar "target")) (EApp (EVar "runDetails") (EVar "result")))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "result")) (EApp (EVar "runFailed") (EVar "result"))) (EApp (EVar "runErrors") (EVar "result")))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "runPassed") (EVar "result"))))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " passed"))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "doctestFailSuffix") (EVar "result")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "runFailed") (EVar "result")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "runErrors") (EVar "result")) (ELit (LInt 0)))))))
(DTypeSig false "propLineTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "propLineTests" ((PVar "tsrc")) (EApp (EVar "collectPropLines") (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "tsrc")))))
(DTypeSig false "collectPropLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "collectPropLines" ((PList)) (EListLit))
(DFunDef false "collectPropLines" ((PCons (PCon "DProp" PWild (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "exprLine") (EVar "body"))) (EApp (EVar "collectPropLines") (EVar "rest"))))
(DFunDef false "collectPropLines" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectPropLines") (EVar "rest")))
(DTypeSig false "elaborateModulesMangled" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "elaborateModulesMangled" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild PWild PWild PWild) () (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE"))))))
(DTypeSig false "runPropsPinned" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyCon "Bool"))))))))))))
(DFunDef false "runPropsPinned" ((PVar "engines") (PVar "pair") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EVar "True") (EIf (EVar "otherwise") (EMatch (EVar "pair") (arm (PCon "TestPairErr" (PVar "err")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "err"))) (DoExpr (EVar "False")))) (arm (PCon "TestPair" (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) () (EApp (EVar "withEvidencePreserved") (ELam (PWild) (EApp (EVar "printGradedPropRows") (EApp (EApp (EApp (EVar "gradeProps") (EMethodRef "index")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEngines") (EVar "engines")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printGradedPropRows" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "printGradedPropRows" ((PList)) (EVar "True"))
(DFunDef false "printGradedPropRows" ((PCons (PVar "row") (PVar "rest"))) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "gradedPropRaw") (EVar "row"))) (DoLet false false (PVar "rawDetail") (EMatch (EApp (EVar "gradedPropPinDetail") (EVar "row")) (arm (PCon "Some" (PVar "pin")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "propResultDetail") (EVar "raw")))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EVar "pin"))) (ELit (LString "")))) (arm (PCon "None") () (EApp (EVar "propResultDetail") (EVar "raw"))))) (DoLet false false (PVar "detail") (EIf (EBinOp "&&" (EApp (EVar "propResultPassed") (EVar "raw")) (EBinOp "==" (EVar "rawDetail") (ELit (LString "")))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "propResultCases") (EVar "raw"))))) (ELit (LString " tests passed"))) (EVar "rawDetail"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Testing \"")) (EApp (EMethodRef "display") (EApp (EVar "propResultName") (EVar "raw")))) (ELit (LString "\" ["))) (EApp (EMethodRef "display") (EApp (EVar "propResultEngine") (EVar "raw")))) (ELit (LString "] ... "))) (EApp (EMethodRef "display") (EIf (EApp (EVar "gradedPropPassed") (EVar "row")) (ELit (LString "OK")) (ELit (LString "FAILED"))))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "detail"))) (ELit (LString ")"))))) (DoLet false false (PVar "restPassed") (EApp (EVar "printGradedPropRows") (EVar "rest"))) (DoExpr (EBinOp "&&" (EApp (EVar "gradedPropPassed") (EVar "row")) (EVar "restPassed")))))
(DTypeSig false "elaboratedRootProps" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "elaboratedRootProps" ((PVar "modules") (PVar "userDecls")) (EMatch (EApp (EVar "lastModule") (EVar "modules")) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls"))))
(DTypeSig false "lastModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "lastModule" ((PList)) (EVar "None"))
(DFunDef false "lastModule" ((PList (PTuple PWild (PVar "decls")))) (EApp (EVar "Some") (EVar "decls")))
(DFunDef false "lastModule" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModule") (EVar "rest")))
(DTypeSig false "runTestDeclsPinned" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyCon "Bool"))))))))))))
(DFunDef false "runTestDeclsPinned" ((PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt") (PVar "file") (PVar "index")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "printGradedTestRows") (EVar "target")) (EApp (EApp (EApp (EVar "gradeTests") (EMethodRef "index")) (EVar "file")) (EApp (EVar "testRowsForPins") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportPinned") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printGradedTestRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "printGradedTestRows" (PWild (PList)) (EVar "True"))
(DFunDef false "printGradedTestRows" ((PVar "target") (PCons (PVar "row") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "raw")) (EApp (EVar "gradedTestRaw") (EVar "row"))) (DoLet false false (PVar "label") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " ["))) (EApp (EMethodRef "display") (EVar "engine"))) (ELit (LString "]")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "printTestRunning") (EVar "target")) (EVar "line")) (EVar "label"))) (DoLet false false PWild (EIf (EBinOp "==" (EApp (EVar "gradedTestStatus") (EVar "row")) (ELit (LString "known-red"))) (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  known-red ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EVar "gradedTestPinDetailText") (EVar "row")))) (ELit (LString ")")))) (EApp (EApp (EApp (EApp (EVar "printTestVerdict") (EVar "target")) (EVar "line")) (EVar "label")) (EVar "raw")))) (DoLet false false (PVar "restPassed") (EApp (EApp (EVar "printGradedTestRows") (EVar "target")) (EVar "rest"))) (DoExpr (EBinOp "&&" (EApp (EVar "gradedTestPassed") (EVar "row")) (EVar "restPassed")))))
(DTypeSig false "gradedTestPinDetailText" (TyFun (TyCon "GradedTest") (TyCon "String")))
(DFunDef false "gradedTestPinDetailText" ((PVar "row")) (EMatch (EApp (EVar "gradedTestPinDetail") (EVar "row")) (arm (PCon "Some" (PVar "detail")) () (EVar "detail")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "testRowsForPins" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))
(DFunDef false "testRowsForPins" ((PList)) (EListLit))
(DFunDef false "testRowsForPins" ((PCons (PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "result")) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EVar "engineName") (EVar "engine")) (EVar "name") (EVar "line") (EVar "result")) (EApp (EVar "testRowsForPins") (EVar "rest"))))
(DTypeSig false "rootTestsOf" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))))
(DFunDef false "rootTestsOf" ((PVar "filterOpt") (PVar "tsrc") (PVar "modsM") (PVar "userDecls")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))))))
(DTypeSig false "nativeRawTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "nativeRawTests" ((PVar "tsrc")) (EApp (EVar "collectTests") (EApp (EVar "parseLocated") (EVar "tsrc"))))
(DTypeSig false "testLineTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "testLineTests" ((PVar "tsrc")) (EApp (EVar "collectTests") (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "tsrc")))))
(DTypeSig false "filterTestsByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))
(DFunDef false "filterTestsByName" ((PCon "None") (PVar "tests")) (EVar "tests"))
(DFunDef false "filterTestsByName" ((PCon "Some" (PVar "sub")) (PVar "tests")) (EApp (EApp (EVar "filterList") (ELam ((PVar "t")) (EApp (EApp (EVar "substringMatch") (EMethodRef "sub")) (EApp (EVar "fst3") (EVar "t"))))) (EVar "tests")))
(DTypeSig false "fst3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "a")))
(DFunDef false "fst3" ((PTuple (PVar "a") PWild PWild)) (EVar "a"))
(DTypeSig false "attachRawLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))
(DFunDef false "attachRawLines" (PWild (PList)) (EListLit))
(DFunDef false "attachRawLines" ((PList) (PCons (PTuple (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (ELit (LInt 0)) (EVar "body")) (EApp (EApp (EVar "attachRawLines") (EListLit)) (EVar "rest"))))
(DFunDef false "attachRawLines" ((PCons (PTuple PWild (PVar "l") PWild) (PVar "rawRest")) (PCons (PTuple (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "l") (EVar "body")) (EApp (EApp (EVar "attachRawLines") (EVar "rawRest")) (EVar "rest"))))
(DTypeSig false "uncapableExternsMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "uncapableExternsMsg" ((PVar "target") (PVar "names")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": `test \"…\"` declarations here reach "))) (EApp (EMethodRef "display") (EApp (EVar "externWord") (EVar "names")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "joinCommas") (EVar "names")))) (ELit (LString ", which `medaka test` does not provide under the interpreter — its capability policy covers the clock, allocation counts and stderr only, so no filesystem, environment, stdin, network or subprocess extern is bound. No test was run. Run these tests natively instead: `medaka test --native "))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "`."))))
(DTypeSig false "externWord" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "externWord" ((PList PWild)) (ELit (LString "the extern")))
(DFunDef false "externWord" (PWild) (ELit (LString "the externs")))
(DTypeSig false "joinCommas" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinCommas" ((PList)) (ELit (LString "")))
(DFunDef false "joinCommas" ((PList (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))))
(DFunDef false "joinCommas" ((PCons (PVar "n") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`, "))) (EApp (EVar "joinCommas") (EVar "rest"))))
(DTypeSig false "printTestRunning" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "printTestRunning" ((PVar "target") (PVar "line") (PVar "name")) (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  running ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "indentVerdictMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "indentVerdictMsg" ((PVar "msg")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "       ")) (EVar "_s")))) (EApp (EVar "splitNl") (EVar "msg")))))
(DTypeSig false "printTestVerdict" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "ExResult") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "printTestVerdict" ((PVar "target") (PVar "line") (PVar "name") (PVar "result")) (EBlock (DoLet false false (PVar "loc") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString "")))) (DoExpr (EMatch (EVar "result") (arm (PCon "Pass" PWild PWild) () (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ok   ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (arm (PCon "Fail" (PVar "msg") PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "putStrLn") (EApp (EVar "indentVerdictMsg") (EVar "msg")))))) (arm (PCon "Errored" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "putStrLn") (EApp (EVar "indentVerdictMsg") (EVar "msg"))))))))))
(DTypeSig true "runTestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))
(DFunDef false "runTestReport" ((PVar "engines") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "target") (PVar "tsrc") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestReportPinned") (EVar "engines")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "target")) (EVar "tsrc")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (ELit (LString ""))) (EVar "omEmpty")))
(DTypeSig false "runTestReportPinned" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))))
(DFunDef false "runTestReportPinned" ((PVar "engines") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "target") (PVar "tsrc") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportMulti") (EVar "engines")) (EVar "runtimeDecls")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (EVar "userDecls")) (EVar "exempt")) (EVar "file")) (EMethodRef "index")) (EMatch (EIf (EVar "exempt") (EVar "None") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (arm (PCon "Some" (PVar "errText")) () (ETuple (EApp (EVar "Some") (EVar "errText")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportSingle") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (EVar "userDecls")) (EVar "exempt")) (EVar "file")) (EMethodRef "index"))))))))
(DTypeSig true "runTestGradedReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "GradedProp")) (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Bool")))))))))))))
(DFunDef false "runTestGradedReport" ((PVar "engines") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "target") (PVar "tsrc") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls")) (ELet false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc"))) (EMatch (EApp (EVar "loadPinContext") (EVar "target")) (arm (PCon "Err" (PVar "err")) () (ETuple (EApp (EVar "Some") (EVar "err")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "Ok" (PVar "context")) () (EMatch (EApp (EApp (EApp (EApp (EVar "validatePinNames") (EFieldAccess (EVar "context") "contextPins")) (EFieldAccess (EVar "context") "contextFile")) (EApp (EVar "propNamesOf") (EVar "userDecls"))) (EApp (EVar "testNamesOf") (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (ETuple (EApp (EVar "Some") (EVar "err")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "Ok" (PLit LUnit)) () (EMatch (EApp (EVar "buildPinIndex") (EFieldAccess (EVar "context") "contextPins")) (arm (PCon "Err" (PVar "err")) () (ETuple (EApp (EVar "Some") (EVar "err")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "Ok" (PVar "index")) () (EBlock (DoLet false false (PTuple (PVar "reportError") (PVar "runs") (PVar "props") (PVar "tests") (PVar "skipped")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestReportPinned") (EVar "engines")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "target")) (EVar "tsrc")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (EFieldAccess (EVar "context") "contextFile")) (EMethodRef "index"))) (DoExpr (ETuple (EVar "reportError") (EVar "runs") (EApp (EApp (EApp (EVar "gradeProps") (EMethodRef "index")) (EFieldAccess (EVar "context") "contextFile")) (EVar "props")) (EApp (EApp (EApp (EVar "gradeTests") (EMethodRef "index")) (EFieldAccess (EVar "context") "contextFile")) (EApp (EVar "testRowsForPins") (EVar "tests"))) (EVar "skipped"))))))))))))
(DTypeSig false "propNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "propNamesOf" ((PList)) (EListLit))
(DFunDef false "propNamesOf" ((PCons (PCon "DProp" PWild (PVar "name") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "name") (EApp (EVar "propNamesOf") (EVar "rest"))))
(DFunDef false "propNamesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "propNamesOf") (EVar "rest")))
(DTypeSig false "testNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "testNamesOf" ((PList)) (EListLit))
(DFunDef false "testNamesOf" ((PCons (PCon "DTest" PWild (PVar "name") PWild) (PVar "rest"))) (EBinOp "::" (EVar "name") (EApp (EVar "testNamesOf") (EVar "rest"))))
(DFunDef false "testNamesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "testNamesOf") (EVar "rest")))
(DTypeSig false "reportMulti" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool"))))))))))))))))))
(DFunDef false "reportMulti" ((PVar "engines") (PVar "runtimeDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls") (PVar "userDecls") (PVar "exempt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "allExamples") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EVar "allExamples"))) (DoLet false false (PVar "synthResults") (EApp (EApp (EVar "buildSynthResults") (EVar "userDecls")) (EVar "examples"))) (DoLet false false (PVar "prepared") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prepareMulti") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "exempt")) (EApp (EVar "isNonEmptyL") (EVar "allExamples"))) (EApp (EVar "buildSynthDecls") (EVar "synthResults")))) (DoExpr (EMatch (EVar "prepared") (arm (PTuple (PCon "Some" (PVar "errText")) PWild) () (ETuple (EApp (EVar "Some") (EVar "errText")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PTuple (PCon "None") (PVar "prepared")) () (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EVar "forcePrepared") (EVar "rsrc")) (EVar "csrc")) (EVar "prepared"))) (DoExpr (ETuple (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReport") (EVar "engines")) (EApp (EVar "DtPair") (EVar "pair"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportPinned") (EVar "engines")) (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportTestDecls") (EVar "includeTestDecls")) (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")) (EVar "exempt")))))))))
(DTypeSig false "reportSingle" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))))))
(DFunDef false "reportSingle" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls") (PVar "userDecls") (PVar "exempt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoLet false false (PVar "doctestRuns") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReport") (EVar "engines")) (EApp (EApp (EApp (EApp (EApp (EVar "DtSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EApp (EApp (EVar "buildSynthResults") (EVar "userDecls")) (EVar "examples")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EBinOp "&&" (EVar "includeTestDecls") (EApp (EVar "hasTests") (EVar "userDecls")))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EApp (EApp (EVar "prepareSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (DoExpr (ETuple (EVar "None") (EVar "doctestRuns") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportPinned") (EVar "engines")) (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportTestDecls") (EVar "includeTestDecls")) (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")) (EVar "exempt")))) (ETuple (EVar "None") (EVar "doctestRuns") (EListLit) (EListLit) (EVar "exempt"))))))
(DTypeSig false "reportTestDecls" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))))))))))
(DFunDef false "reportTestDecls" ((PCon "False") PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "reportTestDecls" ((PCon "True") (PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt") (PVar "file") (PVar "index")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportPinned") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")))
(DTypeSig false "doctestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))))))))))))
(DFunDef false "doctestReport" ((PVar "engines") (PVar "_trees") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PList) (PVar "_synthResults")) (EApp (EVar "emptyDoctestRuns") (EVar "engines")))
(DFunDef false "doctestReport" ((PVar "engines") (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "engines")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))
(DTypeSig false "emptyDoctestRuns" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult")))))
(DFunDef false "emptyDoctestRuns" ((PList)) (EListLit))
(DFunDef false "emptyDoctestRuns" ((PCons (PVar "e") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (EApp (EVar "emptyDoctestRuns") (EVar "rest"))))
(DTypeSig false "doctestReportGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))))))))))))
(DFunDef false "doctestReportGo" ((PList) PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "doctestReportGo" ((PCons (PVar "e") (PVar "rest")) (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "rest")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))))
(DTypeSig false "propsReportPinned" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))
(DFunDef false "propsReportPinned" ((PVar "engines") (PVar "pair") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EListLit) (EIf (EVar "otherwise") (EMatch (EVar "pair") (arm (PCon "TestPairErr" PWild) () (EListLit)) (arm (PCon "TestPair" (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) () (EApp (EVar "withEvidencePreserved") (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEngines") (EVar "engines")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "propsReportEnginesInProcess" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))))))
(DFunDef false "propsReportEnginesInProcess" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "propsReportEnginesInProcess" ((PVar "engines") (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "planningRequests") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EMethodRef "index")) (EVar "file")) (ELit (LString "eval"))) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "planningRequests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEnginesPlain") (EVar "engines")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))) (arm (PCon "Ok" (PTuple (PVar "planEnv") (PVar "planningRows"))) () (EBlock (DoLet false false (PVar "plans") (EApp (EVar "preparedPlans") (EVar "planningRows"))) (DoExpr (EMatch (EApp (EApp (EVar "customPlansReachable") (EVar "planEnv")) (EVar "plans")) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEnginesPlain") (EVar "engines")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))) (arm PWild () (EBlock (DoLet false false (PVar "validation") (EApp (EApp (EApp (EApp (EApp (EVar "validateHelperPlans") (EVar "planEnv")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EVar "plans"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runValidatedPropEngines") (EVar "engines")) (EVar "validation")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")))))))))))))
(DTypeSig false "propsReportEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))))))
(DFunDef false "propsReportEngines" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "propsReportEngines" ((PCons (PCon "EngInterp") (PVar "rest")) (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBinOp "++" (EApp (EApp (EVar "superviseEvalProps") (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EMethodRef "index")) (EVar "file")) (ELit (LString "eval"))) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEngines") (EVar "rest")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))))
(DFunDef false "propsReportEngines" ((PCons (PCon "EngNative") (PVar "rest")) (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEnginesInProcess") (EListLit (EVar "EngNative"))) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEngines") (EVar "rest")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))))
(DTypeSig false "superviseEvalProps" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))
(DFunDef false "superviseEvalProps" (PWild (PList)) (EListLit))
(DFunDef false "superviseEvalProps" ((PVar "target") (PVar "requests")) (EBlock (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EVar "executablePath") (ELit LUnit)))) (DoLet false false (PVar "argv") (EBinOp "++" (EListLit (ELit (LString "test")) (ELit (LString "--props-worker"))) (EApp (EApp (EVar "workerPositionals") (EVar "target")) (EVar "requests")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "medaka")) (EVar "argv")) (arm (PCon "Err" (PVar "message")) () (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EBinOp "++" (EBinOp "++" (ELit (LString "could not start interpreter property worker: ")) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "stdout") (PVar "stderr"))) () (EMatch (EApp (EVar "takeEvalPropBootstrap") (EVar "stdout")) (arm (PCon "Err" (PVar "message")) () (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EVar "workerProtocolRows") (EVar "requests")) (EVar "message")) (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EApp (EApp (EVar "workerAbortDetail") (EVar "code")) (EVar "stderr"))))) (arm (PCon "Ok" (PTuple (PVar "nonce") (PVar "transcript"))) () (EMatch (EApp (EApp (EApp (EVar "decodeEvalPropRows") (EVar "nonce")) (EVar "requests")) (EVar "transcript")) (arm (PCon "Ok" (PVar "rows")) () (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EVar "rows") (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EApp (EApp (EVar "workerAbortDetail") (EVar "code")) (EVar "stderr"))))) (arm (PCon "Err" (PVar "message")) () (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EApp (EApp (EVar "workerProtocolRows") (EVar "requests")) (EVar "message")) (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EApp (EApp (EVar "workerAbortDetail") (EVar "code")) (EVar "stderr")))))))))))))
(DTypeSig false "workerAbortDetail" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "workerAbortDetail" ((PVar "code") (PVar "stderr")) (EBlock (DoLet false false (PVar "first") (EApp (EVar "firstNonEmptyLine") (EApp (EVar "splitNl") (EVar "stderr")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property worker batch aborted (exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))) (EIf (EBinOp "==" (EVar "first") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString " — ")) (EApp (EMethodRef "display") (EVar "first"))) (ELit (LString ""))))))))
(DTypeSig false "workerPositionals" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "workerPositionals" ((PVar "target") (PVar "requests")) (EBinOp "::" (EVar "target") (EApp (EVar "workerRequestPositionals") (EVar "requests"))))
(DTypeSig false "workerRequestPositionals" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "workerRequestPositionals" ((PList)) (EListLit))
(DFunDef false "workerRequestPositionals" ((PCons (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "name"))) (EBinOp "::" (EApp (EVar "stringify") (EApp (EVar "JString") (EApp (EVar "intToString") (EVar "seed")))) (EBinOp "::" (EApp (EVar "stringify") (EApp (EVar "JString") (EApp (EVar "intToString") (EVar "cases")))) (EApp (EVar "workerRequestPositionals") (EVar "rest"))))))
(DTypeSig false "workerRuntimeRows" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "PropResult")))))
(DFunDef false "workerRuntimeRows" ((PList) PWild) (EListLit))
(DFunDef false "workerRuntimeRows" ((PCons (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases")) (PVar "rest")) (PVar "message")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropRuntimeError"))) (EVar "message")) (EVar "seed")) (EVar "cases")) (EApp (EApp (EVar "workerRuntimeRows") (EVar "rest")) (EVar "message"))))
(DTypeSig false "workerProtocolRows" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "PropResult")))))
(DFunDef false "workerProtocolRows" ((PList) PWild) (EListLit))
(DFunDef false "workerProtocolRows" ((PCons (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases")) (PVar "rest")) (PVar "message")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EVar "message")) (EVar "seed")) (EVar "cases")) (EApp (EApp (EVar "workerProtocolRows") (EVar "rest")) (EVar "message"))))
(DTypeSig true "runEvalPropsWorker" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runEvalPropsWorker" ((PVar "target") (PVar "requests")) (EBlock (DoLet false false (PVar "nonce") (EApp (EVar "startEvalPropWorker") (ELit LUnit))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "runtimePath") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "runtimePath")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "evalWorkerDie") (EBinOp "++" (EBinOp "++" (ELit (LString "could not read runtime prelude: ")) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "runtimeSrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "evalWorkerDie") (EBinOp "++" (EBinOp "++" (ELit (LString "could not read core prelude: ")) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "coreSrc")) () (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "evalWorkerDie") (EBinOp "++" (EBinOp "++" (ELit (LString "could not read property target: ")) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" PWild) () (EApp (EVar "evalWorkerDie") (ELit (LString "could not parse property target")))) (arm (PCon "Ok" (PVar "parsed")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPropsWorkerSource") (EVar "target")) (EVar "nonce")) (EVar "requests")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "stdlibDir")) (EVar "tsrc")) (EApp (EVar "desugar") (EVar "parsed"))))))))))))))
(DTypeSig false "evalWorkerDie" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "evalWorkerDie" ((PVar "message")) (ELet false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test --props-worker: ")) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString "")))) (EApp (EVar "exit") (ELit (LInt 1)))))
(DTypeSig false "runEvalPropsWorkerSource" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit")))))))))))
(DFunDef false "runEvalPropsWorkerSource" ((PVar "target") (PVar "nonce") (PVar "requests") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "stdlibDir") (PVar "tsrc") (PVar "userDecls")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoExpr (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EBlock (DoLet false false (PVar "prepared") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prepareMulti") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "target")) (EVar "roots")) (EVar "exempt")) (EVar "False")) (EListLit))) (DoExpr (EMatch (EVar "prepared") (arm (PTuple (PCon "Some" (PVar "message")) PWild) () (EApp (EVar "evalWorkerDie") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "message")))) (arm (PTuple (PCon "None") (PVar "work")) () (EBlock (DoLet false false (PVar "rows") (EApp (EVar "withEvidencePreserved") (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "runEvalRequestRows") (EApp (EApp (EApp (EVar "forcePrepared") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "work"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "requests"))))) (DoExpr (EApp (EApp (EVar "emitEvalPropRows") (EVar "nonce")) (EVar "rows")))))))) (EMatch (EIf (EVar "exempt") (EVar "None") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (arm (PCon "Some" (PVar "message")) () (EApp (EVar "evalWorkerDie") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "message")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "rows") (EApp (EVar "withEvidencePreserved") (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "runEvalRequestRows") (EApp (EApp (EApp (EApp (EApp (EVar "prepareSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "requests"))))) (DoExpr (EApp (EApp (EVar "emitEvalPropRows") (EVar "nonce")) (EVar "rows"))))))))))
(DTypeSig false "runEvalRequestRows" (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runEvalRequestRows" ((PCon "TestPairErr" (PVar "message")) PWild PWild PWild (PVar "requests")) (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property worker could not prepare properties: ")) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString "")))))
(DFunDef false "runEvalRequestRows" ((PCon "TestPair" (PVar "runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "requests")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "requests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "preparedResults") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "preparedPlanError") (ELit (LString "eval"))) (EVar "err"))) (EVar "requests")))) (arm (PCon "Ok" (PTuple (PVar "planEnv") (PVar "rows"))) () (EMatch (EApp (EApp (EVar "customPlansReachable") (EVar "planEnv")) (EApp (EVar "preparedPlans") (EVar "rows"))) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPreparedRows") (EVar "planEnv")) (EListLit)) (EVar "rows")) (EVar "tsrc")) (EVar "coreM")) (EVar "modsM"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EVar "runValidatedEvalRequests") (EApp (EApp (EApp (EApp (EApp (EVar "validateHelperPlans") (EVar "planEnv")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EApp (EVar "preparedPlans") (EVar "rows")))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "requests")))))))))
(DTypeSig false "runValidatedEvalRequests" (TyFun (TyCon "HelperValidation") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runValidatedEvalRequests" ((PCon "HelperValidation" (PVar "pair") (PVar "helpers") (PVar "rejected") (PVar "protocol")) (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "requests")) (EMatch (EVar "protocol") (arm (PCon "Some" (PVar "message")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalProtocolRequests") (EVar "pair")) (EVar "message")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "requests"))) (arm (PCon "None") () (EMatch (EVar "pair") (arm (PCon "TestPairErr" (PVar "message")) () (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property helpers could not prepare: ")) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "TestPair" (PVar "_runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "requests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "preparedResults") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "preparedPlanError") (ELit (LString "eval"))) (EVar "err"))) (EVar "requests")))) (arm (PCon "Ok" (PTuple (PVar "planEnv") (PVar "rows"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPreparedRows") (EVar "planEnv")) (EVar "helpers")) (EApp (EApp (EApp (EApp (EVar "rejectPreparedHelpers") (EVar "planEnv")) (ELit (LString "eval"))) (EVar "rejected")) (EVar "rows"))) (EVar "tsrc")) (EVar "coreM")) (EVar "modsM")))))))))))
(DTypeSig false "runEvalProtocolRequests" (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runEvalProtocolRequests" ((PCon "TestPairErr" (PVar "message")) PWild PWild PWild PWild (PVar "requests")) (EApp (EApp (EVar "workerRuntimeRows") (EVar "requests")) (EBinOp "++" (EBinOp "++" (ELit (LString "interpreter property helpers could not prepare: ")) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString "")))))
(DFunDef false "runEvalProtocolRequests" ((PCon "TestPair" (PVar "_runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) (PVar "message") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "requests")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "requests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "preparedResults") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "preparedPlanError") (ELit (LString "eval"))) (EVar "err"))) (EVar "requests")))) (arm (PCon "Ok" (PTuple (PVar "planEnv") (PVar "rows"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPreparedRows") (EVar "planEnv")) (EListLit)) (EApp (EApp (EApp (EApp (EVar "rejectPreparedProtocolCustom") (EVar "planEnv")) (ELit (LString "eval"))) (EVar "message")) (EVar "rows"))) (EVar "tsrc")) (EVar "coreM")) (EVar "modsM")))))))
(DTypeSig false "runEvalPreparedRows" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runEvalPreparedRows" ((PVar "env") (PVar "helpers") (PVar "rows") (PVar "tsrc") (PVar "coreM") (PVar "modsM")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPreparedPropRequestsResults") (EVar "env")) (EVar "helpers")) (EVar "rows")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EApp (EApp (EApp (EVar "evalModulesRootEvalEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EBinOp "++" (EVar "coreM") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modsM")))))
(DTypeSig false "propsReportEnginesPlain" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))))))
(DFunDef false "propsReportEnginesPlain" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "propsReportEnginesPlain" ((PCons (PCon "EngInterp") (PVar "rest")) (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runAllPlannedPropRequestsResults") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EMethodRef "index")) (EVar "file")) (ELit (LString "eval"))) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EApp (EApp (EApp (EVar "evalModulesRootEvalEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEnginesPlain") (EVar "rest")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))))
(DFunDef false "propsReportEnginesPlain" ((PCons (PCon "EngNative") (PVar "rest")) (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "runNativePlannedPropRequests") (EVar "target")) (EVar "tsrc")) (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EMethodRef "index")) (EVar "file")) (ELit (LString "native"))) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportEnginesPlain") (EVar "rest")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))))
(DTypeSig false "preparedPlans" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyApp (TyCon "List") (TyCon "GenPlan"))))
(DFunDef false "preparedPlans" ((PVar "rows")) (EApp (EApp (EVar "preparedPlansGo") (EVar "rows")) (EListLit)))
(DTypeSig false "preparedPlansGo" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "GenPlan")))))
(DFunDef false "preparedPlansGo" ((PList) (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "preparedPlansGo" ((PCons (PCon "PreparedRun" PWild PWild (PVar "plans")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "preparedPlansGo") (EVar "rest")) (EApp (EApp (EVar "prependPlans") (EVar "plans")) (EVar "acc"))))
(DFunDef false "preparedPlansGo" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "preparedPlansGo") (EVar "rest")) (EVar "acc")))
(DTypeSig false "prependPlans" (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "GenPlan")))))
(DFunDef false "prependPlans" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependPlans" ((PCons (PVar "plan") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "prependPlans") (EVar "rest")) (EBinOp "::" (EVar "plan") (EVar "acc"))))
(DTypeSig false "validateHelperPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "HelperValidation")))))))
(DFunDef false "validateHelperPlans" ((PVar "planEnv") (PVar "runtimeM") (PVar "rawCoreM") (PVar "rawM") (PVar "plans")) (EBlock (DoLet false false (PVar "baseline") (EApp (EVar "helperDiagIndex") (EApp (EApp (EApp (EVar "helperElabDiags") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "validateHelperPlansGo") (EVar "planEnv")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EVar "plans")) (EVar "baseline")) (EVar "omEmpty")))))
(DTypeSig false "validateHelperPlansGo" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "HelperValidation")))))))))
(DFunDef false "validateHelperPlansGo" ((PVar "planEnv") (PVar "runtimeM") (PVar "rawCoreM") (PVar "rawM") (PVar "plans") (PVar "baseline") (PVar "rejected")) (EBlock (DoLet false false (PCon "PropHelpers" (PVar "helpers") (PVar "decls")) (EApp (EApp (EVar "propHelpersForPlans") (EVar "planEnv")) (EVar "plans"))) (DoExpr (EMatch (EVar "helpers") (arm (PList) () (EApp (EApp (EApp (EApp (EVar "HelperValidation") (EApp (EApp (EApp (EApp (EVar "helperPair") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EListLit))) (EListLit)) (EVar "rejected")) (EVar "None"))) (arm PWild () (EBlock (DoLet false false (PVar "candidate") (EApp (EApp (EApp (EApp (EVar "helperPair") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EVar "decls"))) (DoLet false false (PVar "delta") (EApp (EApp (EVar "helperDiagDelta") (EVar "baseline")) (EApp (EApp (EApp (EApp (EVar "helperElabDiagsWith") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EVar "decls")))) (DoLet false false (PVar "helperFiles") (EApp (EApp (EApp (EVar "helperFileIndex") (EVar "helpers")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoLet false false (PTuple (PVar "bad") (PVar "unexpected")) (EApp (EApp (EApp (EApp (EVar "helperDiagFailures") (EVar "helperFiles")) (EVar "delta")) (EVar "omEmpty")) (EVar "False"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omKeys") (EVar "bad")) (EListLit)) (EIf (EVar "unexpected") (EApp (EApp (EApp (EApp (EVar "HelperValidation") (EApp (EApp (EApp (EApp (EVar "helperPair") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EListLit))) (EListLit)) (EVar "rejected")) (EApp (EVar "Some") (ELit (LString "property helper elaboration produced an unattributed diagnostic")))) (EApp (EApp (EApp (EApp (EVar "HelperValidation") (EVar "candidate")) (EVar "helpers")) (EVar "rejected")) (EVar "None"))) (EBlock (DoLet false false (PVar "merged") (EApp (EApp (EVar "mergeHelperFailures") (EVar "rejected")) (EVar "bad"))) (DoLet false false (PVar "kept") (EApp (EApp (EApp (EVar "filterHelperPlans") (EVar "planEnv")) (EVar "merged")) (EVar "plans"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "validateHelperPlansGo") (EVar "planEnv")) (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EVar "kept")) (EVar "baseline")) (EVar "merged"))))))))))))
(DTypeSig false "helperPair" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TestPair"))))))
(DFunDef false "helperPair" ((PVar "runtimeM") (PVar "rawCoreM") (PVar "rawM") (PVar "decls")) (EBlock (DoLet false false (PVar "injected") (EApp (EApp (EVar "injectIntoLast") (EVar "decls")) (EVar "rawM"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "injected")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild PWild PWild PWild) () (EBlock (DoLet false false (PTuple (PVar "coreM") (PVar "modsM")) (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "TestPair") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "injected")) (EVar "modsM")))))))))
(DTypeSig false "helperElabDiags" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))))
(DFunDef false "helperElabDiags" ((PVar "runtimeM") (PVar "rawCoreM") (PVar "rawM")) (EApp (EApp (EApp (EApp (EVar "helperElabDiagsWith") (EVar "runtimeM")) (EVar "rawCoreM")) (EVar "rawM")) (EListLit)))
(DTypeSig false "helperElabDiagsWith" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))))
(DFunDef false "helperElabDiagsWith" ((PVar "runtimeM") (PVar "rawCoreM") (PVar "rawM") (PVar "decls")) (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeM")) (EVar "rawCoreM")) (EApp (EApp (EVar "injectIntoLast") (EVar "decls")) (EVar "rawM"))) (arm (PTuple PWild PWild (PVar "perModule") (PVar "residual") PWild PWild) () (EBinOp "++" (EVar "residual") (EApp (EApp (EVar "perModuleErrors") (EVar "perModule")) (EListLit))))))
(DTypeSig false "perModuleErrors" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))
(DFunDef false "perModuleErrors" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "perModuleErrors" ((PCons (PTuple (PVar "mid") (PTuple (PVar "errors") PWild)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "perModuleErrors") (EVar "rest")) (EApp (EApp (EApp (EVar "prependTcRows") (EVar "mid")) (EVar "errors")) (EVar "acc"))))
(DTypeSig false "prependTcRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "TcDiag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))))
(DFunDef false "prependTcRows" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependTcRows" ((PVar "mid") (PCons (PVar "diag") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "prependTcRows") (EVar "mid")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "mid") (EVar "diag")) (EVar "acc"))))
(DTypeSig false "helperDiagIndex" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "helperDiagIndex" ((PList)) (EVar "omEmpty"))
(DFunDef false "helperDiagIndex" ((PCons (PVar "diag") (PVar "rest"))) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "tcDiagGoalKey") (EVar "diag"))) (ELit LUnit)) (EApp (EVar "helperDiagIndex") (EVar "rest"))))
(DTypeSig false "helperDiagDelta" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))
(DFunDef false "helperDiagDelta" (PWild (PList)) (EListLit))
(DFunDef false "helperDiagDelta" ((PVar "baseline") (PCons (PVar "diag") (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "tcDiagGoalKey") (EVar "diag"))) (EVar "baseline")) (EApp (EApp (EVar "helperDiagDelta") (EVar "baseline")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "diag") (EApp (EApp (EVar "helperDiagDelta") (EVar "baseline")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "helperFileIndex" (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))
(DFunDef false "helperFileIndex" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "helperFileIndex" ((PCons (PCon "PropHelper" (PVar "word") PWild PWild) (PVar "rest")) (PVar "i") (PVar "acc")) (EApp (EApp (EApp (EVar "helperFileIndex") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EBinOp "++" (EBinOp "++" (ELit (LString "<property-helper:")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ">")))) (EVar "word")) (EVar "acc"))))
(DTypeSig false "helperDiagFailures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Bool") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Bool")))))))
(DFunDef false "helperDiagFailures" (PWild (PList) (PVar "bad") (PVar "unexpected")) (ETuple (EVar "bad") (EVar "unexpected")))
(DFunDef false "helperDiagFailures" ((PVar "files") (PCons (PTuple PWild (PCon "TcDiag" PWild PWild (PVar "loc") (PVar "message") PWild PWild)) (PVar "rest")) (PVar "bad") (PVar "unexpected")) (EMatch (EVar "loc") (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "file")) (EVar "files")) (arm (PCon "Some" (PVar "word")) () (EApp (EApp (EApp (EApp (EVar "helperDiagFailures") (EVar "files")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "message")) (EVar "bad"))) (EVar "unexpected"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "helperDiagFailures") (EVar "files")) (EVar "rest")) (EVar "bad")) (EVar "True"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "helperDiagFailures") (EVar "files")) (EVar "rest")) (EVar "bad")) (EVar "True")))))
(DTypeSig false "mergeHelperFailures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DFunDef false "mergeHelperFailures" ((PVar "prior") (PVar "next")) (EApp (EApp (EApp (EVar "mergeHelperFailureKeys") (EApp (EVar "omKeys") (EVar "next"))) (EVar "prior")) (EVar "next")))
(DTypeSig false "mergeHelperFailureKeys" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))
(DFunDef false "mergeHelperFailureKeys" ((PList) (PVar "acc") PWild) (EVar "acc"))
(DFunDef false "mergeHelperFailureKeys" ((PCons (PVar "word") (PVar "rest")) (PVar "acc") (PVar "next")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "next")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "mergeHelperFailureKeys") (EVar "rest")) (EVar "acc")) (EVar "next"))) (arm (PCon "Some" (PVar "message")) () (EApp (EApp (EApp (EVar "mergeHelperFailureKeys") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "message")) (EVar "acc"))) (EVar "next")))))
(DTypeSig false "filterHelperPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "GenPlan"))))))
(DFunDef false "filterHelperPlans" ((PVar "env") (PVar "rejected")) (EApp (EVar "filterList") (EApp (EApp (EVar "planHasNoRejectedCarrier") (EVar "env")) (EVar "rejected"))))
(DTypeSig false "planHasNoRejectedCarrier" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "GenPlan") (TyCon "Bool")))))
(DFunDef false "planHasNoRejectedCarrier" ((PVar "env") (PVar "rejected") (PVar "plan")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "customRejected") (EVar "rejected"))) (EApp (EApp (EVar "customPlansReachable") (EVar "env")) (EListLit (EVar "plan"))))))
(DTypeSig false "plansHaveNoRejectedCarrier" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool")))))
(DFunDef false "plansHaveNoRejectedCarrier" ((PVar "env") (PVar "rejected") (PVar "plans")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "customRejected") (EVar "rejected"))) (EApp (EApp (EVar "customPlansReachable") (EVar "env")) (EVar "plans")))))
(DTypeSig false "customRejected" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "CustomPlan") (TyCon "Bool"))))
(DFunDef false "customRejected" ((PVar "rejected") (PCon "CustomPlan" PWild PWild (PVar "word"))) (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "rejected")))
(DTypeSig false "runValidatedPropEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "HelperValidation") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))
(DFunDef false "runValidatedPropEngines" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "runValidatedPropEngines" ((PVar "engines") (PCon "HelperValidation" (PVar "pair") (PVar "helpers") (PVar "rejected") (PVar "protocol")) (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EMatch (EVar "protocol") (arm (PCon "Some" (PVar "message")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProtocolHelperEngines") (EVar "engines")) (EVar "pair")) (EVar "message")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))) (arm (PCon "None") () (EMatch (EVar "pair") (arm (PCon "TestPairErr" (PVar "message")) () (EApp (EApp (EApp (EApp (EApp (EVar "protocolPropResults") (EVar "engines")) (EVar "message")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (arm (PCon "TestPair" (PVar "_runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runValidatedPropEnginesGo") (EVar "engines")) (EVar "helpers")) (EVar "rejected")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")))))))
(DTypeSig false "runProtocolHelperEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))))
(DFunDef false "runProtocolHelperEngines" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "runProtocolHelperEngines" ((PVar "engines") (PCon "TestPairErr" (PVar "err")) PWild PWild PWild (PVar "userDecls") (PVar "cases") (PVar "filterOpt") PWild PWild) (EApp (EApp (EApp (EApp (EApp (EVar "protocolPropResults") (EVar "engines")) (EVar "err")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")))
(DFunDef false "runProtocolHelperEngines" ((PVar "engines") (PCon "TestPair" (PVar "_runtimeM") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM")) (PVar "message") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProtocolHelperEnginesGo") (EVar "engines")) (EVar "message")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")))
(DTypeSig false "runProtocolHelperEnginesGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))))))))))
(DFunDef false "runProtocolHelperEnginesGo" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "runProtocolHelperEnginesGo" ((PCons (PVar "engine") (PVar "rest")) (PVar "message") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "engineText") (EApp (EVar "engineName") (EVar "engine"))) (DoLet false false (PVar "requests") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EMethodRef "index")) (EVar "file")) (EVar "engineText")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoLet false false (PVar "next") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProtocolHelperEnginesGo") (EVar "rest")) (EVar "message")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "requests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (EBinOp "++" (EApp (EVar "preparedResults") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "preparedPlanError") (EVar "engineText")) (EVar "err"))) (EVar "requests"))) (EVar "next"))) (arm (PCon "Ok" (PTuple (PVar "env") (PVar "prepared"))) () (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EApp (EVar "rejectPreparedProtocolCustom") (EVar "env")) (EVar "engineText")) (EVar "message")) (EVar "prepared"))) (DoLet false false (PVar "here") (EMatch (EVar "engine") (arm (PCon "EngInterp") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPreparedPropRequestsResults") (EVar "env")) (EListLit)) (EVar "rows")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EApp (EApp (EApp (EVar "evalModulesRootEvalEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EBinOp "++" (EVar "coreM") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modsM"))))) (arm (PCon "EngNative") () (EApp (EApp (EApp (EApp (EVar "runPreparedNativeRows") (EVar "rows")) (EVar "target")) (EVar "tsrc")) (EVar "modules"))))) (DoExpr (EBinOp "++" (EVar "here") (EVar "next")))))))))
(DTypeSig false "runValidatedPropEnginesGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))))))))
(DFunDef false "runValidatedPropEnginesGo" ((PList) (PVar "_helpers") (PVar "_rejected") (PVar "_rawCoreM") (PVar "_coreM") (PVar "_rawM") (PVar "_modsM") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PVar "_cases") (PVar "_filterOpt") (PVar "_file") (PVar "_index")) (EListLit))
(DFunDef false "runValidatedPropEnginesGo" ((PCons (PVar "engine") (PVar "rest")) (PVar "helpers") (PVar "rejected") (PVar "rawCoreM") (PVar "coreM") (PVar "rawM") (PVar "modsM") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "engineText") (EApp (EVar "engineName") (EVar "engine"))) (DoLet false false (PVar "requests") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsFor") (EMethodRef "index")) (EVar "file")) (EVar "engineText")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "rootPlanModuleId") (EVar "rawM")) (EVar "target"))) (DoLet false false (PVar "modules") (EApp (EApp (EApp (EApp (EVar "planModules") (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "preparePlannedPropRequests") (EVar "root")) (EVar "modules")) (EVar "requests")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))) (arm (PCon "Err" (PVar "err")) () (EBinOp "++" (EApp (EVar "preparedResults") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "preparedPlanError") (EVar "engineText")) (EVar "err"))) (EVar "requests"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runValidatedPropEnginesGo") (EVar "rest")) (EVar "helpers")) (EVar "rejected")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")))) (arm (PCon "Ok" (PTuple (PVar "env") (PVar "prepared"))) () (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EApp (EVar "rejectPreparedHelpers") (EVar "env")) (EVar "engineText")) (EVar "rejected")) (EVar "prepared"))) (DoLet false false (PVar "here") (EMatch (EVar "engine") (arm (PCon "EngInterp") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPreparedPropRequestsResults") (EVar "env")) (EVar "helpers")) (EVar "rows")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EApp (EApp (EApp (EVar "evalModulesRootEvalEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EBinOp "++" (EVar "coreM") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modsM"))))) (arm (PCon "EngNative") () (EApp (EApp (EApp (EApp (EVar "runPreparedNativeRows") (EVar "rows")) (EVar "target")) (EVar "tsrc")) (EVar "modules"))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runValidatedPropEnginesGo") (EVar "rest")) (EVar "helpers")) (EVar "rejected")) (EVar "rawCoreM")) (EVar "coreM")) (EVar "rawM")) (EVar "modsM")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))))))))))
(DTypeSig false "runPreparedNativeRows" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))
(DFunDef false "runPreparedNativeRows" ((PVar "rows") (PVar "target") (PVar "tsrc") (PVar "modules")) (EApp (EApp (EVar "mergeNativePreparedRows") (EVar "rows")) (EApp (EApp (EApp (EApp (EVar "runNativePlannedPropRequests") (EVar "target")) (EVar "tsrc")) (EVar "modules")) (EApp (EVar "preparedRequests") (EVar "rows")))))
(DTypeSig false "preparedRequests" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyApp (TyCon "List") (TyCon "PropRequest"))))
(DFunDef false "preparedRequests" ((PList)) (EListLit))
(DFunDef false "preparedRequests" ((PCons (PCon "PreparedRun" (PVar "request") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "request") (EApp (EVar "preparedRequests") (EVar "rest"))))
(DFunDef false "preparedRequests" ((PCons PWild (PVar "rest"))) (EApp (EVar "preparedRequests") (EVar "rest")))
(DTypeSig false "preparedResults" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyApp (TyCon "List") (TyCon "PropResult"))))
(DFunDef false "preparedResults" ((PList)) (EListLit))
(DFunDef false "preparedResults" ((PCons (PCon "PreparedResult" (PVar "result")) (PVar "rest"))) (EBinOp "::" (EVar "result") (EApp (EVar "preparedResults") (EVar "rest"))))
(DFunDef false "preparedResults" ((PCons PWild (PVar "rest"))) (EApp (EVar "preparedResults") (EVar "rest")))
(DTypeSig false "mergeNativePreparedRows" (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyCon "PropResult")))))
(DFunDef false "mergeNativePreparedRows" ((PList) (PList)) (EListLit))
(DFunDef false "mergeNativePreparedRows" ((PList) (PCons PWild PWild)) (EListLit (EVar "unexpectedNativeProtocolResult")))
(DFunDef false "mergeNativePreparedRows" ((PCons (PCon "PreparedResult" (PVar "result")) (PVar "rest")) (PVar "native")) (EBinOp "::" (EApp (EApp (EVar "propResultForEngine") (ELit (LString "native"))) (EVar "result")) (EApp (EApp (EVar "mergeNativePreparedRows") (EVar "rest")) (EVar "native"))))
(DFunDef false "mergeNativePreparedRows" ((PCons (PCon "PreparedRun" (PVar "request") PWild PWild) (PVar "rest")) (PList)) (EBinOp "::" (EApp (EVar "nativeProtocolResult") (EVar "request")) (EApp (EApp (EVar "mergeNativePreparedRows") (EVar "rest")) (EListLit))))
(DFunDef false "mergeNativePreparedRows" ((PCons (PCon "PreparedRun" PWild PWild PWild) (PVar "rest")) (PCons (PVar "native") (PVar "nativeRest"))) (EBinOp "::" (EVar "native") (EApp (EApp (EVar "mergeNativePreparedRows") (EVar "rest")) (EVar "nativeRest"))))
(DTypeSig false "preparedPlanError" (TyFun (TyCon "String") (TyFun (TyCon "PlanError") (TyFun (TyCon "PropRequest") (TyCon "PreparedPropRequest")))))
(DFunDef false "preparedPlanError" ((PVar "engine") (PVar "err") (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropCapabilityError"))) (EApp (EVar "planErrorText") (EVar "err"))) (EVar "seed")) (EVar "cases"))))
(DTypeSig false "rejectPreparedHelpers" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyApp (TyCon "List") (TyCon "PreparedPropRequest")))))))
(DFunDef false "rejectPreparedHelpers" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "rejectPreparedHelpers" ((PVar "env") (PVar "engine") (PVar "rejected") (PCons (PAs "row" (PCon "PreparedResult" PWild)) (PVar "rest"))) (EBinOp "::" (EVar "row") (EApp (EApp (EApp (EApp (EVar "rejectPreparedHelpers") (EVar "env")) (EVar "engine")) (EVar "rejected")) (EVar "rest"))))
(DFunDef false "rejectPreparedHelpers" ((PVar "env") (PVar "engine") (PVar "rejected") (PCons (PAs "row" (PCon "PreparedRun" (PVar "request") PWild (PVar "plans"))) (PVar "rest"))) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EApp (EApp (EVar "rejectPreparedHelpers") (EVar "env")) (EVar "engine")) (EVar "rejected")) (EVar "rest"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "plansHaveNoRejectedCarrier") (EVar "env")) (EVar "rejected")) (EVar "plans")) (EBinOp "::" (EVar "row") (EVar "next")) (EBinOp "::" (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EApp (EApp (EVar "helperCapabilityResult") (EVar "env")) (EVar "engine")) (EVar "request")) (EVar "rejected")) (EVar "plans"))) (EVar "next"))))))
(DTypeSig false "rejectPreparedProtocolCustom" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyApp (TyCon "List") (TyCon "PreparedPropRequest")))))))
(DFunDef false "rejectPreparedProtocolCustom" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "rejectPreparedProtocolCustom" ((PVar "env") (PVar "engine") (PVar "message") (PCons (PAs "row" (PCon "PreparedResult" PWild)) (PVar "rest"))) (EBinOp "::" (EVar "row") (EApp (EApp (EApp (EApp (EVar "rejectPreparedProtocolCustom") (EVar "env")) (EVar "engine")) (EVar "message")) (EVar "rest"))))
(DFunDef false "rejectPreparedProtocolCustom" ((PVar "env") (PVar "engine") (PVar "message") (PCons (PAs "row" (PCon "PreparedRun" (PVar "request") PWild (PVar "plans"))) (PVar "rest"))) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EApp (EApp (EVar "rejectPreparedProtocolCustom") (EVar "env")) (EVar "engine")) (EVar "message")) (EVar "rest"))) (DoExpr (EMatch (EApp (EApp (EVar "customPlansReachable") (EVar "env")) (EVar "plans")) (arm (PList) () (EBinOp "::" (EVar "row") (EVar "next"))) (arm PWild () (EBinOp "::" (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EVar "helperProtocolResult") (EVar "engine")) (EVar "message")) (EVar "request"))) (EVar "next")))))))
(DTypeSig false "helperProtocolResult" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyCon "PropResult")))))
(DFunDef false "helperProtocolResult" ((PVar "engine") (PVar "message") (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EVar "message")) (EVar "seed")) (EVar "cases")))
(DTypeSig false "helperCapabilityResult" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "PropRequest") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "PropResult")))))))
(DFunDef false "helperCapabilityResult" ((PVar "env") (PVar "engine") (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases")) (PVar "rejected") (PVar "plans")) (EMatch (EApp (EApp (EVar "firstRejectedCarrier") (EVar "rejected")) (EApp (EApp (EVar "customPlansReachable") (EVar "env")) (EVar "plans"))) (arm (PCon "Some" (PCon "CustomPlan" PWild (PVar "carrier") (PVar "word"))) () (EBlock (DoLet false false (PVar "detail") (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "rejected")) (arm (PCon "Some" (PVar "message")) () (EVar "message")) (arm (PCon "None") () (ELit (LString "typed helper could not be elaborated"))))) (DoLet false false (PVar "err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "name")) (ELit (LString "$property-helper"))) (EVar "carrier")) (EVar "PEUnusableArbitrary")) (EVar "detail"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropCapabilityError"))) (EApp (EVar "planErrorText") (EVar "err"))) (EVar "seed")) (EVar "cases"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "property helper rejection lost its carrier"))) (EVar "seed")) (EVar "cases")))))
(DTypeSig false "firstRejectedCarrier" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyApp (TyCon "Option") (TyCon "CustomPlan")))))
(DFunDef false "firstRejectedCarrier" (PWild (PList)) (EVar "None"))
(DFunDef false "firstRejectedCarrier" ((PVar "rejected") (PCons (PAs "custom" (PCon "CustomPlan" PWild PWild (PVar "word"))) (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "rejected")) (EApp (EVar "Some") (EVar "custom")) (EIf (EVar "otherwise") (EApp (EApp (EVar "firstRejectedCarrier") (EVar "rejected")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nativeProtocolResult" (TyFun (TyCon "PropRequest") (TyCon "PropResult")))
(DFunDef false "nativeProtocolResult" ((PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "native property runner returned no selected result"))) (EVar "seed")) (EVar "cases")))
(DTypeSig false "unexpectedNativeProtocolResult" (TyCon "PropResult"))
(DFunDef false "unexpectedNativeProtocolResult" () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "native"))) (ELit (LString "<native property runner>"))) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "native property runner returned an unexpected selected result"))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "propResultForEngine" (TyFun (TyCon "String") (TyFun (TyCon "PropResult") (TyCon "PropResult"))))
(DFunDef false "propResultForEngine" ((PVar "engine") (PCon "PropResult" PWild (PVar "name") (PVar "status") (PVar "kind") (PVar "detail") (PVar "seed") (PVar "cases"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "status")) (EVar "kind")) (EVar "detail")) (EVar "seed")) (EVar "cases")))
(DTypeSig false "protocolPropResults" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PropResult"))))))))
(DFunDef false "protocolPropResults" ((PList) PWild PWild PWild PWild) (EListLit))
(DFunDef false "protocolPropResults" ((PCons (PVar "engine") (PVar "rest")) (PVar "message") (PVar "userDecls") (PVar "cases") (PVar "filterOpt")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "protocolPropsForEngine") (EApp (EVar "engineName") (EVar "engine"))) (EVar "message")) (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "userDecls")))) (EVar "cases")) (EApp (EApp (EApp (EApp (EApp (EVar "protocolPropResults") (EVar "rest")) (EVar "message")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))))
(DTypeSig false "protocolPropsForEngine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "PropResult")))))))
(DFunDef false "protocolPropsForEngine" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "protocolPropsForEngine" ((PVar "engine") (PVar "message") (PCons (PCon "DProp" PWild (PVar "name") PWild PWild) (PVar "rest")) (PVar "cases")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (EVar "engine")) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EVar "message")) (EApp (EVar "propSeedValue") (ELit LUnit))) (EVar "cases")) (EApp (EApp (EApp (EApp (EVar "protocolPropsForEngine") (EVar "engine")) (EVar "message")) (EVar "rest")) (EVar "cases"))))
(DFunDef false "protocolPropsForEngine" ((PVar "engine") (PVar "message") (PCons PWild (PVar "rest")) (PVar "cases")) (EApp (EApp (EApp (EApp (EVar "protocolPropsForEngine") (EVar "engine")) (EVar "message")) (EVar "rest")) (EVar "cases")))
(DTypeSig false "planModules" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "PlanModule")))))))
(DFunDef false "planModules" ((PVar "rawCore") (PVar "coreM") (PVar "rawModules") (PVar "runtimeModules")) (EBinOp "::" (EApp (EApp (EApp (EVar "PlanModule") (ELit (LString "core"))) (EVar "rawCore")) (EVar "coreM")) (EApp (EApp (EVar "planModulesGo") (EVar "rawModules")) (EVar "runtimeModules"))))
(DTypeSig false "planModulesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "PlanModule")))))
(DFunDef false "planModulesGo" ((PList) (PList)) (EListLit))
(DFunDef false "planModulesGo" ((PCons (PTuple (PVar "_rawId") (PVar "rawDecls")) (PVar "rawRest")) (PCons (PTuple (PVar "runtimeId") (PVar "runtimeDecls")) (PVar "runtimeRest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "PlanModule") (EVar "runtimeId")) (EVar "rawDecls")) (EVar "runtimeDecls")) (EApp (EApp (EVar "planModulesGo") (EVar "rawRest")) (EVar "runtimeRest"))))
(DFunDef false "planModulesGo" (PWild PWild) (EListLit))
(DTypeSig false "rootPlanModuleId" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "rootPlanModuleId" ((PList) (PVar "fallback")) (EVar "fallback"))
(DFunDef false "rootPlanModuleId" ((PList (PTuple (PVar "moduleId") PWild)) PWild) (EVar "moduleId"))
(DFunDef false "rootPlanModuleId" ((PCons PWild (PVar "rest")) (PVar "fallback")) (EApp (EApp (EVar "rootPlanModuleId") (EVar "rest")) (EVar "fallback")))
(DTypeSig false "propRequestsFor" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PropRequest")))))))))
(DFunDef false "propRequestsFor" ((PVar "index") (PVar "file") (PVar "engine") (PVar "userDecls") (PVar "cases") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsForGo") (EMethodRef "index")) (EVar "file")) (EVar "engine")) (EApp (EVar "propSeedValue") (ELit LUnit))) (EVar "cases")) (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "userDecls")))))
(DTypeSig false "propRequestsForGo" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "PropRequest")))))))))
(DFunDef false "propRequestsForGo" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "propRequestsForGo" ((PVar "index") (PVar "file") (PVar "engine") (PVar "seed") (PVar "cases") (PCons (PCon "DProp" PWild (PVar "name") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "request") (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "pinFromIndex") (EMethodRef "index")) (EVar "file")) (EVar "PropPin")) (EVar "name")) (EVar "engine")) (arm (PCon "Some" (PVar "pin")) () (EApp (EApp (EApp (EVar "PropRequest") (EVar "name")) (EApp (EApp (EVar "pinSeedOr") (EVar "seed")) (EVar "pin"))) (EApp (EApp (EVar "pinCasesOr") (EVar "cases")) (EVar "pin")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "PropRequest") (EVar "name")) (EVar "seed")) (EVar "cases"))))) (DoExpr (EBinOp "::" (EVar "request") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsForGo") (EMethodRef "index")) (EVar "file")) (EVar "engine")) (EVar "seed")) (EVar "cases")) (EVar "rest"))))))
(DFunDef false "propRequestsForGo" ((PVar "index") (PVar "file") (PVar "engine") (PVar "seed") (PVar "cases") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propRequestsForGo") (EMethodRef "index")) (EVar "file")) (EVar "engine")) (EVar "seed")) (EVar "cases")) (EVar "rest")))
(DTypeSig false "pinSeedOr" (TyFun (TyCon "Int") (TyFun (TyCon "TestPin") (TyCon "Int"))))
(DFunDef false "pinSeedOr" ((PVar "fallback") (PVar "pin")) (EMatch (EFieldAccess (EVar "pin") "pinSeed") (arm (PCon "Some" (PVar "seed")) () (EVar "seed")) (arm (PCon "None") () (EVar "fallback"))))
(DTypeSig false "pinCasesOr" (TyFun (TyCon "Int") (TyFun (TyCon "TestPin") (TyCon "Int"))))
(DFunDef false "pinCasesOr" ((PVar "fallback") (PVar "pin")) (EMatch (EFieldAccess (EVar "pin") "pinCases") (arm (PCon "Some" (PVar "cases")) () (EVar "cases")) (arm (PCon "None") () (EVar "fallback"))))
(DTypeSig false "testDeclsReportPinned" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))))
(DFunDef false "testDeclsReportPinned" ((PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt") (PVar "file") (PVar "index")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportEngines") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "testDeclsReportEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))))
(DFunDef false "testDeclsReportEngines" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "testDeclsReportEngines" ((PCons (PVar "e") (PVar "rest")) (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "tagWithEngine") (EVar "e")) (EVar "t")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportOn") (EVar "e")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportEngines") (EVar "rest")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "file")) (EMethodRef "index"))))
(DTypeSig false "tagWithEngine" (TyFun (TyCon "Engine") (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")) (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))
(DFunDef false "tagWithEngine" ((PVar "e") (PTuple (PVar "name") (PVar "line") (PVar "result"))) (ETuple (EVar "e") (EVar "name") (EVar "line") (EVar "result")))
(DTypeSig false "testDeclsReportOn" (TyFun (TyCon "Engine") (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))))
(DFunDef false "testDeclsReportOn" ((PCon "EngInterp") (PCon "TestPairErr" PWild) (PVar "_runtimeDecls") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PVar "_filterOpt") (PVar "_file") (PVar "_index")) (EListLit))
(DFunDef false "testDeclsReportOn" ((PCon "EngInterp") (PCon "TestPair" (PVar "_runtimeM") (PVar "_rawCoreM") (PVar "coreM") (PVar "_rawM") (PVar "modsM")) (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt") (PVar "_file") (PVar "_index")) (EApp (EApp (EApp (EApp (EVar "gatedTestsCollect") (EVar "target")) (EBinOp "++" (EBinOp "++" (EVar "runtimeDecls") (EVar "coreM")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modsM")))) (EApp (EApp (EApp (EVar "evalModulesRootEvalEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EApp (EApp (EApp (EApp (EVar "rootTestsOf") (EVar "filterOpt")) (EVar "tsrc")) (EVar "modsM")) (EVar "userDecls"))))
(DFunDef false "testDeclsReportOn" ((PCon "EngNative") (PVar "_pair") (PVar "_runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "_userDecls") (PVar "filterOpt") (PVar "file") (PVar "index")) (EBlock (DoLet false false (PVar "tests") (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EVar "nativeRawTests") (EVar "tsrc")))) (DoLet false false (PVar "ordinary") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "notExpectedNativeError") (EMethodRef "index")) (EVar "file"))) (EVar "tests"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestsWithPinnedErrors") (EVar "target")) (EVar "tsrc")) (EMethodRef "index")) (EVar "file")) (EVar "tests")) (EApp (EApp (EApp (EVar "runNativeTests") (EVar "target")) (EVar "tsrc")) (EVar "ordinary"))))))
(DTypeSig false "notExpectedNativeError" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")) (TyCon "Bool")))))
(DFunDef false "notExpectedNativeError" ((PVar "index") (PVar "file") (PTuple (PVar "name") PWild PWild)) (EApp (EVar "not") (EApp (EApp (EApp (EVar "isExpectedNativeError") (EMethodRef "index")) (EVar "file")) (EVar "name"))))
(DTypeSig false "isExpectedNativeError" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isExpectedNativeError" ((PVar "index") (PVar "file") (PVar "name")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "pinFromIndex") (EMethodRef "index")) (EVar "file")) (EVar "TestPin")) (EVar "name")) (ELit (LString "native"))) (arm (PCon "Some" (PVar "pin")) () (EMatch (EFieldAccess (EVar "pin") "pinExpected") (arm (PCon "Some" (PCon "ExpectError" PWild)) () (EVar "True")) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "nativeTestsWithPinnedErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "ExResult")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))))))
(DFunDef false "nativeTestsWithPinnedErrors" (PWild PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "nativeTestsWithPinnedErrors" ((PVar "target") (PVar "tsrc") (PVar "index") (PVar "file") (PCons (PAs "selected" (PTuple (PVar "name") (PVar "line") PWild)) (PVar "rest")) (PVar "ordinary")) (EIf (EApp (EApp (EApp (EVar "isExpectedNativeError") (EMethodRef "index")) (EVar "file")) (EVar "name")) (EMatch (EApp (EApp (EApp (EVar "runNativeTests") (EVar "target")) (EVar "tsrc")) (EListLit (EVar "selected"))) (arm (PList (PVar "result")) () (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EVar "result")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestsWithPinnedErrors") (EVar "target")) (EVar "tsrc")) (EMethodRef "index")) (EVar "file")) (EVar "rest")) (EVar "ordinary")))) (arm PWild () (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EApp (EVar "Errored") (ELit (LString "native test runner returned no selected result")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestsWithPinnedErrors") (EVar "target")) (EVar "tsrc")) (EMethodRef "index")) (EVar "file")) (EVar "rest")) (EVar "ordinary"))))) (EMatch (EVar "ordinary") (arm (PList) () (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EApp (EVar "Errored") (ELit (LString "native test runner returned no selected result")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestsWithPinnedErrors") (EVar "target")) (EVar "tsrc")) (EMethodRef "index")) (EVar "file")) (EVar "rest")) (EListLit)))) (arm (PCons (PVar "result") (PVar "ordinaryRest")) () (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EVar "result")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestsWithPinnedErrors") (EVar "target")) (EVar "tsrc")) (EMethodRef "index")) (EVar "file")) (EVar "rest")) (EVar "ordinaryRest")))))))
(DTypeSig false "gatedTestsCollect" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))))
(DFunDef false "gatedTestsCollect" ((PVar "target") (PVar "corpus") (PVar "env") (PVar "tests")) (EMatch (EApp (EApp (EApp (EVar "uncapableExternsEnv") (EVar "corpus")) (EVar "env")) (EVar "tests")) (arm (PList) () (EApp (EApp (EVar "runTestsCollectEnv") (EVar "env")) (EVar "tests"))) (arm (PVar "names") () (EBlock (DoLet false false (PVar "msg") (EApp (EApp (EVar "uncapableExternsMsg") (EVar "target")) (EVar "names"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (ETuple (EApp (EVar "fst3") (EVar "t")) (EApp (EVar "snd3") (EVar "t")) (EApp (EVar "Errored") (EVar "msg"))))) (EVar "tests")))))))
(DTypeSig false "snd3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "b")))
(DFunDef false "snd3" ((PTuple PWild (PVar "b") PWild)) (EVar "b"))
(DTypeSig false "runTestsCollectEnv" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))
(DFunDef false "runTestsCollectEnv" (PWild (PList)) (EListLit))
(DFunDef false "runTestsCollectEnv" ((PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EApp (EApp (EVar "runOneTestEnv") (EVar "env")) (EVar "body"))) (EApp (EApp (EVar "runTestsCollectEnv") (EVar "env")) (EVar "rest"))))
(DTypeSig true "testHelpText" (TyCon "String"))
(DFunDef false "testHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka test — Run doctests + property tests\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka test [--native | --engines eval,native] [--json] [--filter <substring>]\n")) (ELit (LString "              [--seed <n>] [--cases <n>] [file.mdk | dir]\n")) (ELit (LString "\n")) (ELit (LString "  --native            run doctests, properties and `test \"…\"` decls through a\n")) (ELit (LString "                      compiled native binary (the default; shorthand\n")) (ELit (LString "                      for --engines native)\n")) (ELit (LString "  --engines e1,e2,...  run the listed engine set (known: eval, native);\n")) (ELit (LString "                      exit code is the AND across engines. `eval` is\n")) (ELit (LString "                      the interpreter; property tests follow this selection\n")) (ELit (LString "  --json               emit a {\"file\":...,\"engine\":...,\"doctests\":...,\n")) (ELit (LString "                      \"properties\":...,\"tests\":...,\"summary\":...} JSON\n")) (ELit (LString "                      object instead of human text (single file.mdk target\n")) (ELit (LString "                      only; agrees with the human report's pass/fail counts\n")) (ELit (LString "                      on all three phases)\n")) (ELit (LString "  --filter <substring> restrict to doctests/`test \"…\"`/`prop \"…\"` whose\n")) (ELit (LString "                      name (or, for a doctest, input expression) contains\n")) (ELit (LString "                      <substring>\n")) (ELit (LString "  --seed <n>           seed the property-test RNG (printed on every prop\n")) (ELit (LString "                      failure so the counterexample is replayable); never\n")) (ELit (LString "                      affects a program under test's own random draws\n")) (ELit (LString "  --cases <n>           run each property with <n> generated cases\n")) (ELit (LString "                      instead of the default 100\n")) (ELit (LString "\n")) (ELit (LString "--native and --engines are mutually exclusive. With neither, the default\n")) (ELit (LString "is the native backend alone.\n")) (ELit (LString "\n")) (ELit (LString "With no target, tests the project containing the current directory: the\n")) (ELit (LString "nearest directory at or above it with a medaka.toml, walked like a dir\n")) (ELit (LString "target. Outside any project, pass a file.mdk or dir target.\n")))))
(DTypeSig true "testArgSpec" (TyCon "ArgSpec"))
(DFunDef false "testArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "test"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--native")))) (ELit (LString "shorthand for --engines native"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--engines")))) (ELit (LString "eval,native"))) (ELit (LString "engines to run each example under"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--filter")))) (ELit (LString "SUBSTRING"))) (ELit (LString "run only matching examples"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--seed")))) (ELit (LString "N"))) (ELit (LString "seed the property RNG"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--cases")))) (ELit (LString "N"))) (ELit (LString "property cases per test"))) (EApp (EVar "internal") (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--props-worker")))) (ELit (LString "INTERNAL: run isolated interpreter properties"))))))))
(DTypeSig true "parseTestIntFlag" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "parseTestIntFlag" ((PVar "nm") (PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (EVar "nm")) (EVar "a")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Some" (PVar "s")) () (EMatch (EApp (EVar "toInt") (EVar "s")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "n")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "nm"))) (ELit (LString " requires an integer value, got '"))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "'")))))))))
(DTypeSig true "parseTestCasesFlag" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "parseTestCasesFlag" ((PVar "a")) (EMatch (EApp (EApp (EVar "parseTestIntFlag") (ELit (LString "--cases"))) (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PCon "None")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Ok" (PCon "Some" (PVar "n"))) () (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--cases requires a positive integer value, got '")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "'")))) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "n")))))))
(DTypeSig true "parseTestEngines" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseTestEngines" ((PVar "a")) (EMatch (ETuple (EApp (EApp (EVar "flagValue") (ELit (LString "--engines"))) (EVar "a")) (EApp (EApp (EVar "flag") (ELit (LString "--native"))) (EVar "a"))) (arm (PTuple (PCon "Some" PWild) (PCon "True")) () (EApp (EVar "Err") (ELit (LString "--native and --engines are mutually exclusive; --native is shorthand for --engines native")))) (arm (PTuple (PCon "Some" (PVar "spec")) (PCon "False")) () (EApp (EVar "parseEngineList") (EVar "spec"))) (arm (PTuple (PCon "None") (PCon "True")) () (EApp (EVar "Ok") (EListLit (EVar "EngNative")))) (arm (PTuple (PCon "None") (PCon "False")) () (EApp (EVar "Ok") (EListLit (EVar "EngNative"))))))
(DTypeSig false "parseEngineList" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseEngineList" ((PVar "spec")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EApp (EMethodRef "map") (EVar "stringTrim")) (EApp (EVar "splitLintNames") (EVar "spec"))))) (DoExpr (EMatch (EVar "names") (arm (PList) () (EApp (EVar "Err") (ELit (LString "--engines requires at least one of: eval, native")))) (arm PWild () (EApp (EVar "parseEngineNames") (EVar "names")))))))
(DTypeSig false "parseEngineNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseEngineNames" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "parseEngineNames" ((PCons (PVar "n") (PVar "rest"))) (EMatch (EApp (EVar "engineOfName") (EVar "n")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown engine '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' (known: eval, native)"))))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "e") (EVar "_s")))) (EApp (EVar "parseEngineNames") (EVar "rest"))))))
(DTypeSig false "engineOfName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Engine"))))
(DFunDef false "engineOfName" ((PLit (LString "eval"))) (EApp (EVar "Some") (EVar "EngInterp")))
(DFunDef false "engineOfName" ((PLit (LString "native"))) (EApp (EVar "Some") (EVar "EngNative")))
(DFunDef false "engineOfName" (PWild) (EVar "None"))
(DTypeSig true "runTestOne" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "runTestOne" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "target")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "target")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig true "cliTestReportOk" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool"))))))
(DFunDef false "cliTestReportOk" ((PVar "typeError") (PVar "runs") (PVar "props") (PVar "tests")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNone") (EVar "typeError")) (EApp (EVar "cliAllDoctestRunsOk") (EVar "runs"))) (EApp (EVar "cliAllPropsPass") (EVar "props"))) (EApp (EVar "cliAllTestsPass") (EVar "tests"))))
(DTypeSig false "cliAllDoctestRunsOk" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyCon "Bool")))
(DFunDef false "cliAllDoctestRunsOk" ((PList)) (EVar "True"))
(DFunDef false "cliAllDoctestRunsOk" ((PCons (PTuple PWild (PVar "run")) (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "runFailed") (EVar "run")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "runErrors") (EVar "run")) (ELit (LInt 0)))) (EApp (EVar "cliAllDoctestRunsOk") (EVar "rest"))))
(DTypeSig false "cliAllPropsPass" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Bool")))
(DFunDef false "cliAllPropsPass" ((PList)) (EVar "True"))
(DFunDef false "cliAllPropsPass" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "propResultPassed") (EVar "p")) (EApp (EVar "cliAllPropsPass") (EVar "rest"))))
(DTypeSig false "cliAllTestsPass" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))
(DFunDef false "cliAllTestsPass" ((PList)) (EVar "True"))
(DFunDef false "cliAllTestsPass" ((PCons (PTuple PWild PWild PWild (PCon "Pass" PWild PWild)) (PVar "rest"))) (EApp (EVar "cliAllTestsPass") (EVar "rest")))
(DFunDef false "cliAllTestsPass" ((PCons PWild PWild)) (EVar "False"))
(DTypeSig false "cliPrimaryDoctestRun" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyCon "RunResult")))
(DFunDef false "cliPrimaryDoctestRun" ((PList)) (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DFunDef false "cliPrimaryDoctestRun" ((PCons (PTuple PWild (PVar "run")) PWild)) (EVar "run"))
(DTypeSig false "cliCountPassProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "cliCountPassProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountPassProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "cliCountPassProps") (EVar "rest"))))
(DTypeSig false "cliCountFailProps" (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyCon "Int")))
(DFunDef false "cliCountFailProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountFailProps" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "cliCountFailProps") (EVar "rest"))))
(DTypeSig false "cliCountPassTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Int")))
(DFunDef false "cliCountPassTests" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountPassTests" ((PCons (PTuple PWild PWild PWild (PCon "Pass" PWild PWild)) (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "cliCountPassTests") (EVar "rest"))))
(DFunDef false "cliCountPassTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "cliCountPassTests") (EVar "rest")))
(DTypeSig false "cliCountFailTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Int")))
(DFunDef false "cliCountFailTests" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountFailTests" ((PCons (PTuple PWild PWild PWild (PCon "Pass" PWild PWild)) (PVar "rest"))) (EApp (EVar "cliCountFailTests") (EVar "rest")))
(DFunDef false "cliCountFailTests" ((PCons PWild (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "cliCountFailTests") (EVar "rest"))))
(DTypeSig false "cliExampleJson" (TyFun (TyTuple (TyCon "Example") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "cliExampleJson" ((PTuple (PVar "ex") (PVar "res"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EApp (EVar "exampleLine") (EVar "ex")))) (ETuple (ELit (LString "input")) (EApp (EVar "JString") (EApp (EVar "exampleInput") (EVar "ex"))))) (EApp (EVar "exResultJsonFields") (EVar "res")))))
(DTypeSig false "cliDoctestsJson" (TyFun (TyCon "RunResult") (TyCon "Json")))
(DFunDef false "cliDoctestsJson" ((PVar "run")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "total")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "run")) (EApp (EVar "runFailed") (EVar "run"))) (EApp (EVar "runErrors") (EVar "run"))))) (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EApp (EVar "runPassed") (EVar "run")))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EApp (EVar "runFailed") (EVar "run")))) (ETuple (ELit (LString "errors")) (EApp (EVar "JInt") (EApp (EVar "runErrors") (EVar "run")))) (ETuple (ELit (LString "examples")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "cliExampleJson")) (EApp (EVar "runDetails") (EVar "run"))))))))
(DTypeSig false "cliPropJson" (TyFun (TyCon "PropResult") (TyCon "Json")))
(DFunDef false "cliPropJson" () (EVar "propResultJson"))
(DTypeSig false "cliTestJson" (TyFun (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "cliTestJson" ((PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "result"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "engineName") (EVar "engine"))))) (EApp (EVar "exResultJsonFields") (EVar "result")))))
(DTypeSig false "cliTypeErrorField" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliTypeErrorField" ((PCon "None")) (EListLit))
(DFunDef false "cliTypeErrorField" ((PCon "Some" (PVar "errText"))) (EListLit (ETuple (ELit (LString "typeError")) (EApp (EVar "JString") (EVar "errText")))))
(DTypeSig false "cliTypecheckSkippedField" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliTypecheckSkippedField" ((PCon "False")) (EListLit))
(DFunDef false "cliTypecheckSkippedField" ((PCon "True")) (EListLit (ETuple (ELit (LString "typecheckSkipped")) (EApp (EVar "JBool") (EVar "True")))))
(DTypeSig false "cliDoctestRunEngineNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "Engine"))))
(DFunDef false "cliDoctestRunEngineNames" ((PList)) (EListLit))
(DFunDef false "cliDoctestRunEngineNames" ((PCons (PTuple (PVar "e") PWild) (PVar "rest"))) (EBinOp "::" (EVar "e") (EApp (EVar "cliDoctestRunEngineNames") (EVar "rest"))))
(DTypeSig false "cliPrimaryEngineName" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyCon "String")))
(DFunDef false "cliPrimaryEngineName" ((PList)) (ELit (LString "unknown")))
(DFunDef false "cliPrimaryEngineName" ((PCons (PVar "e") PWild)) (EApp (EVar "engineName") (EVar "e")))
(DTypeSig true "cliTestReportJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyFun (TyCon "Bool") (TyCon "Json")))))))))
(DFunDef false "cliTestReportJson" ((PVar "path") (PVar "typeError") (PVar "engines") (PVar "runs") (PVar "props") (PVar "tests") (PVar "typecheckSkipped")) (EBlock (DoLet false false (PVar "runEngines") (EIf (EApp (EVar "isNone") (EVar "typeError")) (EApp (EVar "cliDoctestRunEngineNames") (EVar "runs")) (EVar "engines"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "cliPrimaryEngineName") (EVar "runEngines"))))) (EApp (EVar "cliTypeErrorField") (EVar "typeError"))) (EApp (EVar "cliTypecheckSkippedField") (EVar "typecheckSkipped"))) (EListLit (ETuple (ELit (LString "doctests")) (EApp (EVar "cliDoctestsJson") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "cliPropJson")) (EVar "props")))) (ETuple (ELit (LString "tests")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "cliTestJson")) (EVar "tests")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "cliCountPassProps") (EVar "props"))) (EApp (EVar "cliCountPassTests") (EVar "tests"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "runErrors") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (EApp (EVar "cliCountFailProps") (EVar "props"))) (EApp (EVar "cliCountFailTests") (EVar "tests"))))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EApp (EApp (EVar "cliTestReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")) (EVar "tests")))))))))))))
(DTypeSig true "cliGradedTestReportOk" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Bool"))))))
(DFunDef false "cliGradedTestReportOk" ((PVar "reportError") (PVar "runs") (PVar "props") (PVar "tests")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNone") (EVar "reportError")) (EApp (EVar "cliAllDoctestRunsOk") (EVar "runs"))) (EApp (EVar "allGradedPropsPass") (EVar "props"))) (EApp (EVar "allGradedTestsPass") (EVar "tests"))))
(DTypeSig false "allGradedPropsPass" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Bool")))
(DFunDef false "allGradedPropsPass" ((PList)) (EVar "True"))
(DFunDef false "allGradedPropsPass" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "gradedPropPassed") (EVar "row")) (EApp (EVar "allGradedPropsPass") (EVar "rest"))))
(DTypeSig false "allGradedTestsPass" (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Bool")))
(DFunDef false "allGradedTestsPass" ((PList)) (EVar "True"))
(DFunDef false "allGradedTestsPass" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "&&" (EApp (EVar "gradedTestPassed") (EVar "row")) (EApp (EVar "allGradedTestsPass") (EVar "rest"))))
(DTypeSig false "cliGradedPropJson" (TyFun (TyCon "GradedProp") (TyCon "Json")))
(DFunDef false "cliGradedPropJson" ((PVar "row")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "gradedPropRaw") (EVar "row"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "propResultEngine") (EVar "raw")))) (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "propResultName") (EVar "raw")))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EApp (EVar "gradedPropStatus") (EVar "row")))) (ETuple (ELit (LString "rawStatus")) (EApp (EVar "JString") (EApp (EVar "gradedPropRawStatus") (EVar "row")))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EApp (EVar "propResultDetail") (EVar "raw")))) (ETuple (ELit (LString "failureKind")) (EApp (EVar "propFailureKindJson") (EApp (EVar "propResultFailureKind") (EVar "raw")))) (ETuple (ELit (LString "seed")) (EApp (EVar "JInt") (EApp (EVar "propResultSeed") (EVar "raw")))) (ETuple (ELit (LString "cases")) (EApp (EVar "JInt") (EApp (EVar "propResultCases") (EVar "raw"))))) (EApp (EVar "cliIssueField") (EApp (EVar "gradedPropIssue") (EVar "row")))) (EApp (EVar "cliPinField") (EApp (EVar "gradedPropPinDetail") (EVar "row"))))))))
(DTypeSig false "cliGradedTestJson" (TyFun (TyCon "GradedTest") (TyCon "Json")))
(DFunDef false "cliGradedTestJson" ((PVar "row")) (EBlock (DoLet false false (PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "raw")) (EApp (EVar "gradedTestRaw") (EVar "row"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EVar "engine"))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EApp (EVar "gradedTestStatus") (EVar "row")))) (ETuple (ELit (LString "rawStatus")) (EApp (EVar "JString") (EApp (EVar "gradedTestRawStatus") (EVar "row"))))) (EApp (EVar "cliRawTestOperands") (EVar "raw"))) (EApp (EVar "cliIssueField") (EApp (EVar "gradedTestIssue") (EVar "row")))) (EApp (EVar "cliPinField") (EApp (EVar "gradedTestPinDetail") (EVar "row"))))))))
(DTypeSig false "cliRawTestOperands" (TyFun (TyCon "ExResult") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliRawTestOperands" ((PCon "Pass" (PVar "expected") (PVar "actual"))) (EListLit (ETuple (ELit (LString "expected")) (EApp (EVar "JString") (EVar "expected"))) (ETuple (ELit (LString "actual")) (EApp (EVar "JString") (EVar "actual")))))
(DFunDef false "cliRawTestOperands" ((PCon "Fail" (PVar "detail") (PVar "expected") (PVar "actual"))) (EBinOp "++" (EListLit (ETuple (ELit (LString "expected")) (EApp (EVar "JString") (EVar "expected"))) (ETuple (ELit (LString "actual")) (EApp (EVar "JString") (EVar "actual")))) (EIf (EBinOp "==" (EVar "detail") (ELit (LString ""))) (EListLit) (EListLit (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail")))))))
(DFunDef false "cliRawTestOperands" ((PCon "Errored" (PVar "detail"))) (EListLit (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EVar "detail")))))
(DTypeSig false "cliIssueField" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliIssueField" ((PCon "None")) (EListLit))
(DFunDef false "cliIssueField" ((PCon "Some" (PVar "issue"))) (EListLit (ETuple (ELit (LString "issue")) (EApp (EVar "JInt") (EVar "issue")))))
(DTypeSig false "cliPinField" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliPinField" ((PCon "None")) (EListLit))
(DFunDef false "cliPinField" ((PCon "Some" (PVar "detail"))) (EListLit (ETuple (ELit (LString "pin")) (EApp (EVar "JString") (EVar "detail")))))
(DTypeSig false "cliCountPassedGradedProps" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Int")))
(DFunDef false "cliCountPassedGradedProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountPassedGradedProps" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "&&" (EApp (EVar "propResultPassed") (EApp (EVar "gradedPropRaw") (EVar "row"))) (EApp (EVar "gradedPropPassed") (EVar "row"))) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "cliCountPassedGradedProps") (EVar "rest"))))
(DTypeSig false "cliCountFailedGradedProps" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Int")))
(DFunDef false "cliCountFailedGradedProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountFailedGradedProps" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "gradedPropPassed") (EVar "row")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "cliCountFailedGradedProps") (EVar "rest"))))
(DTypeSig false "cliCountPassedGradedTests" (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Int")))
(DFunDef false "cliCountPassedGradedTests" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountPassedGradedTests" ((PCons (PVar "row") (PVar "rest"))) (EBlock (DoLet false false (PTuple PWild PWild PWild (PVar "raw")) (EApp (EVar "gradedTestRaw") (EVar "row"))) (DoExpr (EBinOp "+" (EIf (EBinOp "&&" (EApp (EVar "rawTestPassed") (EVar "raw")) (EApp (EVar "gradedTestPassed") (EVar "row"))) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EVar "cliCountPassedGradedTests") (EVar "rest"))))))
(DTypeSig false "rawTestPassed" (TyFun (TyCon "ExResult") (TyCon "Bool")))
(DFunDef false "rawTestPassed" ((PCon "Pass" PWild PWild)) (EVar "True"))
(DFunDef false "rawTestPassed" (PWild) (EVar "False"))
(DTypeSig false "cliCountFailedGradedTests" (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Int")))
(DFunDef false "cliCountFailedGradedTests" ((PList)) (ELit (LInt 0)))
(DFunDef false "cliCountFailedGradedTests" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "+" (EIf (EApp (EVar "gradedTestPassed") (EVar "row")) (ELit (LInt 0)) (ELit (LInt 1))) (EApp (EVar "cliCountFailedGradedTests") (EVar "rest"))))
(DTypeSig true "cliGradedTestReportJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyFun (TyCon "Bool") (TyCon "Json")))))))))
(DFunDef false "cliGradedTestReportJson" ((PVar "path") (PVar "reportError") (PVar "engines") (PVar "runs") (PVar "props") (PVar "tests") (PVar "typecheckSkipped")) (EBlock (DoLet false false (PVar "runEngines") (EIf (EApp (EVar "isNone") (EVar "reportError")) (EApp (EVar "cliDoctestRunEngineNames") (EVar "runs")) (EVar "engines"))) (DoLet false false (PVar "known") (EBinOp "+" (EApp (EVar "knownRedCountProps") (EVar "props")) (EApp (EVar "knownRedCountTests") (EVar "tests")))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "cliPrimaryEngineName") (EVar "runEngines"))))) (EApp (EVar "cliTypeErrorField") (EVar "reportError"))) (EApp (EVar "cliTypecheckSkippedField") (EVar "typecheckSkipped"))) (EListLit (ETuple (ELit (LString "doctests")) (EApp (EVar "cliDoctestsJson") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "cliGradedPropJson")) (EVar "props")))) (ETuple (ELit (LString "tests")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "cliGradedTestJson")) (EVar "tests")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "cliCountPassedGradedProps") (EVar "props"))) (EApp (EVar "cliCountPassedGradedTests") (EVar "tests"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "runErrors") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (EApp (EVar "cliCountFailedGradedProps") (EVar "props"))) (EApp (EVar "cliCountFailedGradedTests") (EVar "tests"))))) (ETuple (ELit (LString "knownRed")) (EApp (EVar "JInt") (EVar "known"))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EApp (EApp (EVar "cliGradedTestReportOk") (EVar "reportError")) (EVar "runs")) (EVar "props")) (EVar "tests")))))))))))))
(DTypeSig true "checkTestMdkRoster" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "checkTestMdkRoster" ((PVar "root") (PVar "targets") (PVar "files")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "git"))) (EBinOp "++" (EListLit (ELit (LString "ls-files")) (ELit (LString "--full-name")) (ELit (LString "--"))) (EVar "targets"))) (arm (PCon "Err" PWild) () (EVar "True")) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "tracked") (EApp (EApp (EVar "filterList") (EApp (EVar "endsWith") (ELit (LString "_test.mdk")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitNl") (EVar "out"))))) (DoLet false false (PVar "relFiles") (EApp (EApp (EMethodRef "map") (EApp (EVar "stripRootPrefix") (EVar "root"))) (EVar "files"))) (DoLet false false (PVar "missing") (EApp (EApp (EVar "filterList") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "t")) (EVar "relFiles"))))) (EVar "tracked"))) (DoExpr (EMatch (EVar "missing") (arm (PList) () (EVar "True")) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: git-tracked but not discovered: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "missing")))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))) (arm (PCon "Ok" (PTuple PWild PWild PWild)) () (EVar "True"))))
(DTypeSig false "stripRootPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripRootPrefix" ((PVar "root") (PVar "p")) (EBlock (DoLet false false (PVar "prefix") (EBinOp "++" (EVar "root") (ELit (LString "/")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "p")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "p"))) (EVar "p")) (EVar "p")))))
(DTypeSig false "testChildArgs" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "testChildArgs" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "seedOpt") (PVar "f")) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "test")) (EVar "f") (ELit (LString "--engines")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "engineName")) (EVar "engines"))) (ELit (LString "--cases")) (EApp (EVar "intToString") (EVar "cases"))) (EMatch (EVar "filterOpt") (arm (PCon "Some" (PVar "s")) () (EListLit (ELit (LString "--filter")) (EVar "s"))) (arm (PCon "None") () (EListLit)))) (EMatch (EVar "seedOpt") (arm (PCon "Some" (PVar "s")) () (EListLit (ELit (LString "--seed")) (EApp (EVar "intToString") (EVar "s")))) (arm (PCon "None") () (EListLit)))))
(DTypeSig true "testFilesGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))))))
(DFunDef false "testFilesGo" (PWild PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "testFilesGo" ((PVar "engines") (PVar "rtPath") (PVar "corePath") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "seedOpt") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EVar "executablePath") (ELit LUnit)))) (DoLet false false (PVar "args") (EApp (EApp (EApp (EApp (EApp (EVar "testChildArgs") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EVar "f"))) (DoLet false false (PVar "ok") (EMatch (EApp (EApp (EVar "runCommand") (EVar "medaka")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString ": failed to start test runner: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "out"))) (DoLet false false PWild (EApp (EVar "flushStdout") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EVar "True") (EBlock (DoLet false false PWild (EApp (EVar "ePutStr") (EVar "err"))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString ": DEAD (child exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))))) (DoExpr (EVar "False"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EApp (EVar "not") (EVar "ok")))))))
