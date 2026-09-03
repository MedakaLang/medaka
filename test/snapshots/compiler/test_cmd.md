# META
source_lines=1579
stages=DESUGAR,MARK
# SOURCE
-- compiler/test_cmd.mdk — `medaka test` logic (doctests + property tests),
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
-- (loadProgram + elaborateModules + evalModules), so cross-module instances/values
-- resolve.  Neither path calls the flat elaborateDict/evalProgram anymore.
-- ARCH E-5 (#1521, owns #1223): `rootId` is `canonicalPathId deps roots target`
-- — the SAME canonicalized id a sibling's `import <name>` resolves to when it
-- reaches this file through `loadProgram`/`runMulti` (`canonicalModId`'s
-- last-containing-root, round-trip-guarded convention — NOT plain
-- `moduleIdOfPath`'s first-root, which agrees with it only when a project has
-- one root; a target below its own `medaka.toml` is the case that needs the
-- distinction, see `canonicalPathId`'s own comment in `driver/loader.mdk`), so a
-- module that is simultaneously a test target and a sibling's import dependency
-- carries one identity, not two — REGARDLESS of whether the two files share a
-- directory: `canonicalPathId`'s last-containing-root convention depends only
-- on the SET OF ROOTS each file's own `entrySearchRoots` walk reaches (both
-- walk up to the SAME `medaka.toml`, wherever each file sits under it), not on
-- the two files being siblings in one directory.  `test/origin_fixtures/nested`
-- is the CROSS-DIRECTORY witness: `main_nested.mdk` sits at the fixture root
-- and `src/leaf.mdk` is nested a directory below it, and the two AGREE.
-- Previously this was the synthetic literal `"__user__"`, hardcoded at all four
-- single-file call sites below.

import frontend.ast.{Decl, DData, DInterface, DProp, Expr(..), Loc(..)}
import frontend.parser.{parse, parseLocated, parseResult}
import frontend.desugar.{desugar}
import frontend.desugar_cache.{desugaredPrelude}
import driver.loader.{
  loadProgram,
  entrySearchRoots,
  canonicalPathId,
  readDeps,
  findProjectRootOrSelf,
}
import driver.build_cmd.{readPreludeFile}
import types.typecheck.{elaborateOne, elaborateModules}
import backend.private_mangle.{mangleCtorCollisionsPair}
import frontend.lexer.{collectComments}
import eval.eval.{
  Value,
  evalOneWith,
  evalModulesWith,
  evalModulesRootEnvWith,
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
}
import tools.native_doctest.{runNativeDoctests}
import tools.prop_runner.{runAllProps, hasProps, runAllPropsResults, PropResult}
import tools.test_runner.{collectTests, runOneTest, hasTests}
import driver.diagnostics.{
  analyzeProject,
  analyzeLocated,
  readDiagSrc,
  ppDiagCliSrc,
  ppDiagCliLines,
  srcLinesArr,
  parseErrDiag,
  Diag,
  diagIsError,
}
import support.util.{
  listLen,
  joinNl,
  isNonEmptyL,
  filterList,
  endsWith,
  splitOnChar,
}
import support.path.{dirOf}

-- `medaka test --filter <substring>`: does `needle` occur anywhere in
-- `haystack`? Same tiny definition as `prop_runner.mdk`'s copy — not shared
-- via support/util.mdk to keep this slice's snapshot bless scoped to the
-- files it names.
substringMatch : String -> String -> Bool
substringMatch needle haystack = isSome (stringIndexOf needle haystack)

export
rootsOrDefault : String -> List String -> List String
rootsOrDefault target [] = [dirOf target]
rootsOrDefault _ roots = roots

-- Returns True iff every doctest AND every prop passed.  A file that parses
-- clean with zero doctests/props is vacuously True (nothing ran, nothing
-- failed).  A read error — on either prelude source OR the target itself —
-- returns False (P0-212): a file that couldn't even be opened is a FAILURE,
-- not a vacuous pass, so callers that gate `exit 1` on this Bool (rather than
-- on the printed report, since the report is prose, not a signal) see it.
-- `engines` selects which execution engine(s) render each doctest example's
-- actual value — `[EngInterp]` (the default, byte-identical to pre-#81-Stage-3
-- behavior), `[EngNative]` under `medaka test --native` (SWAPS the engine,
-- doesn't add one), or an explicit `--engines eval,native` list. It has NO
-- effect on the prop/`test "…"` phases, which remain interpreter-only.
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
      Ok csrc => match readFile target
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
            match doctestGate target roots rsrc csrc tsrc userDecls
              Some errText =>
                let _ = ePutStrLn (typecheckGateFail target errText)
                False
              -- S-1/#2234 (F-converge): the prelude halves go through the
              -- content-keyed `desugaredPrelude` memo; only the USER source is
              -- parsed+desugared fresh here.
              None =>
                driveAll
                  engines
                  (desugaredPrelude rsrc)
                  (desugaredPrelude csrc)
                  target
                  tsrc
                  roots
                  cases
                  filterOpt

-- ── typecheck gate (issues #260, #1229) ──────────────────────────────────────
-- `medaka test` used to GREEN-LIGHT a module whose DOCTESTS `medaka check`
-- REJECTS: the doctest driver ELABORATES the module (dict-passing) but never
-- surfaces the accumulated type errors, so a module with type errors — even ones
-- in functions no doctest exercises — passed `test` while `check` failed
-- (test-green / check-dies, the repo's #1 bug class INVERTED, reproduced building
-- stdlib/bits64).  So type-check the whole module FIRST — exactly the way `medaka
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
-- The exemption used to be keyed on doctests ALONE (`[] => None`), so a module
-- with NO test-facing construct of any kind — no doctest, no `test "…"`, no
-- `prop "…"` — skipped the gate too, printed `(no doctests found)` and exited 0
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
-- test/ported/*.mdk and sqlite/test/*_test.mdk must keep exiting 0.
-- ⚠️ It goes to STDERR, not stdout: the doctest/prop/test reports on stdout are
-- parsed for counts by `sqlite/test/inlang_test_oracle.sh` (`grep -c '^  ok   '`)
-- and by `test/diff_compiler_ported.sh`, and a line injected into that stream
-- would be graded as report text.  `diff_compiler_ported.sh` classifies stderr by
-- `^runtime error \[E-PANIC\]`, which this note cannot match.
-- The exemption PREDICATE alone, with no side effect — shared by `doctestGate`
-- (the printing CLI arm) and `typecheckGateResult` (the silent, data-returning
-- arm `runTestReport`/`medaka mcp`'s `medaka_test` uses, #1443).  Doctest
-- presence still wins over the `test`/`prop` exemption (same precedence as
-- before the factor-out).
--
-- #1445/#2513: the exemption is narrowed by PATH, not just by decl shape —
-- `isNewVehiclePath` below excludes the `[P-TEST-SIBLING]` `*_test.mdk`
-- convention (AGENTS.md) so a compiler-/stdlib-internal test sibling is always
-- type-checked, never silently swallowed the way `test/ported/*.mdk` and
-- `sqlite/test/*_test.mdk` deliberately still are.
typecheckExempt : String -> List Decl -> String -> <IO> Bool
typecheckExempt target userDecls tsrc
  | isNonEmptyL (extractExamples (collectComments tsrc)) = False
  | isNewVehiclePath target = False
  | otherwise = hasProps userDecls || hasTests userDecls

-- The `[P-TEST-SIBLING]` convention (AGENTS.md): a `*_test.mdk` sibling under
-- `compiler/` or `stdlib/` is the new in-tree test vehicle (S-2), and must not
-- inherit the `test`/`prop` exemption meant for the eval-vs-check divergence
-- corpus (`test/ported/*.mdk`, `sqlite/test/*_test.mdk`) — those predate this
-- convention, share only the suffix, and keep the exemption unchanged.  Scoped
-- by PATH so the two `_test.mdk` families stay distinguishable: suffix alone
-- cannot tell them apart.
--
-- The path test is a `/`-delimited SEGMENT match over the CANONICALIZED target,
-- not a substring test over the string the CLI was handed.  Both halves are
-- load-bearing, and a bare `substringMatch "compiler/"` got each one wrong in
-- the opposite direction:
--   • canonicalization, because the classification must not depend on the
--     invocation FORM.  `medaka test compiler/types/x_test.mdk` and, from
--     inside that directory, `medaka test x_test.mdk` name the same module; the
--     second carries no `compiler/` substring, so the substring form silently
--     re-exempted the file the convention exists to guard.
--   • segment matching, because `compiler`/`stdlib` must be real path
--     components.  A tree under `…/mycompiler/…` or `…/newstdlib/…` contains
--     the substring without containing the directory, and the substring form
--     newly type-checked files (the sqlite corpus among them) that are
--     deliberately exempt.
-- `canonicalizePath` returns its input unchanged on an unresolvable path, so an
-- already-relative, already-`compiler/`-rooted target still classifies the same.
isNewVehiclePath : String -> <IO> Bool
isNewVehiclePath target =
  if endsWith "_test.mdk" target then
    hasVehicleSegment (canonicalizePath target)
  else
    False

-- Is `compiler` or `stdlib` a whole `/`-delimited component of `path`?
hasVehicleSegment : String -> Bool
hasVehicleSegment path =
  isNonEmptyL
    (filterList
      (seg => seg == "compiler" || seg == "stdlib")
      (splitOnChar '/' path))

doctestGate : String ->
  List String ->
  String ->
  String ->
  String ->
  List Decl ->
  <IO> Option String
doctestGate target roots rsrc csrc tsrc userDecls
  | typecheckExempt target userDecls tsrc =
    let _ = ePutStrLn (typecheckSkipNotice target userDecls)
    None
  | otherwise = typecheckErrors target roots rsrc csrc tsrc userDecls

-- Same decision as `doctestGate`, minus the stderr announcement — for a
-- non-printing caller (`runTestReport`) that has no stderr channel of its own
-- to put the exemption notice on (#1443).  An exempted module still skips the
-- type check and returns `None` here, silently; a module that fails the type
-- check still returns `Some <located error text>`, exactly as `doctestGate`
-- would report it to a human.
export
typecheckGateResult : String ->
  List String ->
  String ->
  String ->
  String ->
  List Decl ->
  <IO> Option String
typecheckGateResult target roots rsrc csrc tsrc userDecls
  | typecheckExempt target userDecls tsrc = None
  | otherwise = typecheckErrors target roots rsrc csrc tsrc userDecls

-- Type-check the module the way `medaka check` does, routing by import-presence
-- to mirror the CLI's own `check`:
--   • prelude-only (no non-core imports): `analyzeLocated` (the single-file
--     analyzer `medaka check` uses).  It correctly handles the target==prelude
--     case (`medaka test stdlib/core.mdk`, the neq-hang canary) via the shared
--     shadow-scoping, and is UNGUARDED for internal-only externs so a stdlib
--     module that calls `arrayGetUnsafe` &co. is not spuriously rejected.
--   • import-bearing: `analyzeProject` (the multi-module diagnostic engine
--     `medaka check`/`--json` use), which loads the real sibling graph — the
--     single-file analyzer would flag every non-core import as UnknownModule.
-- Returns Some <located error text> iff the module does NOT typecheck, else None.
typecheckErrors : String ->
  List String ->
  String ->
  String ->
  String ->
  List Decl ->
  <IO> Option String
typecheckErrors target roots rsrc csrc tsrc userDecls
  | hasUseDecls userDecls = projectTypeErrors target roots rsrc csrc
  | otherwise = singleFileTypeErrors target tsrc rsrc csrc

singleFileTypeErrors : String -> String -> String -> String -> Option String
singleFileTypeErrors target tsrc rsrc csrc =
  let errs = filter diagIsError (analyzeLocated rsrc csrc tsrc)
  match errs
    [] => None
    _ => Some (joinNl (map (ppDiagCliLines (srcLinesArr tsrc) target) errs))

-- #1362: `singleFileTypeErrors` above uses the UNGUARDED `analyzeLocated` (no
-- internal-extern restriction) so a stdlib module under test is never
-- spuriously rejected; keep this multi-module twin unguarded too
-- (`allowInternal = True`, `trustedMods = []`) for the same reason — `medaka
-- test` is not the internal-extern enforcement surface (`check`/`--json` is).
projectTypeErrors : String ->
  List String ->
  String ->
  String ->
  <IO> Option String
projectTypeErrors target roots rsrc csrc =
  let cacheRef = Ref []
  let parseCacheRef = Ref []
  let results =
    analyzeProject
      True
      []
      cacheRef
      parseCacheRef
      (_ => None)
      target
      roots
      rsrc
      csrc
  let triples = map readDiagSrc results
  let rendered = flatMap renderFileErrors triples
  match rendered
    [] => None
    _ => Some (joinNl rendered)

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

driveAll : List Engine ->
  List Decl ->
  List Decl ->
  String ->
  String ->
  List String ->
  Int ->
  Option String ->
  <IO> Bool
driveAll engines runtimeDecls coreDecls target tsrc roots cases filterOpt =
  let userDecls = desugar (parse tsrc)
  let doctestsOk =
    runDoctests
      engines
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      filterOpt
  let propsOk =
    runProps runtimeDecls coreDecls target tsrc userDecls roots cases filterOpt
  let testsOk =
    runTestDecls runtimeDecls coreDecls target tsrc userDecls roots filterOpt
  doctestsOk && propsOk && testsOk

-- ── doctest phase ────────────────────────────────────────────────────────────

-- `medaka test --filter <substring>` (#2295) keeps only examples whose input
-- expression contains the substring — doctests have no separate "name", the
-- input line IS the identity a reader would filter by.
filterExamplesByName : Option String -> List Example -> List Example
filterExamplesByName None examples = examples
filterExamplesByName (Some sub) examples =
  filterList (ex => substringMatch sub (exampleInput ex)) examples

runDoctests : List Engine ->
  List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Option String ->
  <IO> Bool
runDoctests engines runtimeDecls coreDecls target tsrc userDecls roots filterOpt =
  let _ = putStrLn ("running doctests in " ++ target)
  let examples =
    filterExamplesByName filterOpt (extractExamples (collectComments tsrc))
  match examples
    [] =>
      let _ = putStrLn "  (no doctests found)"
      True
    _ =>
      let synthResults = buildSynthResults examples
      let synthDecls = buildSynthDecls synthResults
      runEngines
        engines
        runtimeDecls
        coreDecls
        target
        tsrc
        userDecls
        roots
        examples
        synthDecls
        synthResults

-- Run the doctests under each requested engine in turn, AND-ing pass/fail
-- across engines. With exactly one engine — `[EngInterp]`, the default — the
-- report is BYTE-IDENTICAL to `medaka test`'s pre-#81-Stage-3 output: no
-- engine tag is printed, and only ONE build/run happens. `--native` adds
-- `EngNative` to the list, and each engine's block is labelled so the two
-- reports (and their independent pass/fail) don't run together.
runEngines : List Engine ->
  List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  List Example ->
  List Decl ->
  List (Result String (List Decl)) ->
  <IO> Bool
runEngines [e] runtimeDecls coreDecls target tsrc userDecls roots examples synthDecls synthResults =
  let result =
    runChosenOn
      e
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      examples
      synthDecls
      synthResults
  reportDoctests target result
runEngines engines runtimeDecls coreDecls target tsrc userDecls roots examples synthDecls synthResults =
  runEnginesTagged
    engines
    runtimeDecls
    coreDecls
    target
    tsrc
    userDecls
    roots
    examples
    synthDecls
    synthResults

runEnginesTagged : List Engine ->
  List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  List Example ->
  List Decl ->
  List (Result String (List Decl)) ->
  <IO> Bool
runEnginesTagged [] _ _ _ _ _ _ _ _ _ = True
runEnginesTagged (e :: rest) runtimeDecls coreDecls target tsrc userDecls roots examples synthDecls synthResults =
  let _ = putStrLn ""
  let _ = putStrLn "-- \{engineName e} --"
  let result =
    runChosenOn
      e
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      examples
      synthDecls
      synthResults
  let ok = reportDoctests target result
  let restOk =
    runEnginesTagged
      rest
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      examples
      synthDecls
      synthResults
  ok && restOk

-- ── engine dispatch (#81 Stage 3) ────────────────────────────────────────────
-- The SINGLE call site that picks an execution engine. `EngInterp` runs
-- `runChosen` (today's interpreter path, verbatim); `EngNative` compiles the
-- module to a real native binary via `tools.native_doctest` (Stage 2) and runs
-- that. Both arms judge through the SAME `buildDetailsFrom` seam (one inside
-- `runChosen`/`runSingle`/`runMulti`, the other inside `runNativeDoctests`
-- itself) — extraction, synth generation, and judging are never duplicated
-- here, only the execution engine differs.
export
runChosenOn : Engine ->
  List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  List Example ->
  List Decl ->
  List (Result String (List Decl)) ->
  <IO> RunResult
runChosenOn EngInterp runtimeDecls coreDecls target _tsrc userDecls roots examples synthDecls synthResults =
  runChosen
    runtimeDecls
    coreDecls
    target
    userDecls
    roots
    examples
    synthDecls
    synthResults
runChosenOn EngNative _runtimeDecls _coreDecls target tsrc userDecls _roots examples _synthDecls synthResults =
  runNativeDoctests target tsrc userDecls examples synthResults

runChosen : List Decl ->
  List Decl ->
  String ->
  List Decl ->
  List String ->
  List Example ->
  List Decl ->
  List (Result String (List Decl)) ->
  <IO> RunResult
runChosen runtimeDecls coreDecls target userDecls roots examples synthDecls synthResults
  | hasUseDecls userDecls =
    runMulti
      runtimeDecls
      coreDecls
      target
      userDecls
      roots
      examples
      synthDecls
      synthResults
  | otherwise =
    runSingle
      runtimeDecls
      coreDecls
      target
      userDecls
      roots
      examples
      synthDecls
      synthResults

-- ── The interpreter's adapter onto doctest.mdk's buildDetailsFrom seam ──────
-- buildDetailsFrom (Stage 1) wants "one rendered actual per example, or one
-- whole-file error" — not a raw interpreter env. This is the thin adapter:
-- for each example i, look up its synthesized `__dt_i__` binding in the post-
-- run env and render it, exactly as the pre-Stage-1 `oneResult` did inline.
renderExamples : List (String, Value e) ->
  List Example ->
  <e> List (Result String String)
renderExamples env examples = renderExamplesGo env 0 examples

renderExamplesGo : List (String, Value e) ->
  Int ->
  List Example ->
  <e> List (Result String String)
renderExamplesGo _ _ [] = []
renderExamplesGo env i (ex :: rest) =
  renderOneExample env i ex :: renderExamplesGo env (i + 1) rest

-- No binding for __dt_i__ means that example's synth never ran (its own
-- decl was dropped, or the file errored before reaching it) — reported the
-- same way the interpreter always has: "could not evaluate: <expr>".
renderOneExample : List (String, Value e) ->
  Int ->
  Example ->
  <e> Result String String
renderOneExample env i ex = match lookupBinding (synthName i) env
  None => Err ("could not evaluate: " ++ exampleInput ex)
  Some v => Ok (ppValue (force v))

-- ARCH E-5 (#1521/#1223): the loader-derived id for a single-file test target —
-- shared by all four single-file drivers below.  `deps` mirrors
-- `loadProgramFilesE`'s own `readDeps (findProjectRootOrSelf (parentDir entry))`
-- (`dirOf` here is that same "parent directory of the target" computation, just
-- imported from `support.path` rather than loader's private copy).
--
-- EXPORTED (#1526 blocker-2 follow-up): `origin_agreement_main.mdk`'s `single`
-- probe arm imports and calls this DIRECTLY, rather than reimplementing the id
-- derivation independently — a prior version recomputed it inline, which meant
-- the gate could drift out of sync with this function silently (a change here
-- with no matching probe update would go undetected). Calling this export means
-- the gate now tracks whatever this function does, mechanically, by construction.
export
singleRootId : List String -> String -> <IO> String
singleRootId roots target =
  let deps = readDeps (findProjectRootOrSelf (dirOf target))
  canonicalPathId deps roots target

-- Single-file path: drop shadowed prelude, append synth, dict-elaborate, run.
-- When the file under test IS the prelude (`medaka test stdlib/core.mdk`), it
-- already declares everything the prelude provides, so prepending the prelude
-- would duplicate every top-level decl (two `Bounded Char` impls, etc.) and
-- corrupt return-position dispatch.  Mirror the `programIsCore` guard below:
-- skip the prelude prepend for core.
-- Single-file (no-import) path, DRIVER-COLLAPSE Phase 1+3: route the degenerate
-- no-import file through the SAME multi-module path as an import-bearing one — the
-- 1-module wrappers (elaborateOne → evalOne).  elaborateModules owns the dict-set
-- (its `moduleDictNames` return-position subset == coreDictNames's non-core case:
-- preludeReturnPosDictNames ++ the file's constrained sigs, arg-position helpers
-- excluded so the `neq`-hang stays closed).  livePrelude is the shadow-dropped core,
-- passed SEPARATE (elaborateOne folds it in); for `medaka test stdlib/core.mdk`
-- (programIsCore) livePrelude is [] so the prelude is not double-prepended.  evalOne's
-- rootLocals carry the synthesized __dt_i__ bindings (same as runMulti).
runSingle : List Decl ->
  List Decl ->
  String ->
  List Decl ->
  List String ->
  List Example ->
  List Decl ->
  List (Result String (List Decl)) ->
  <IO> RunResult
runSingle runtimeDecls coreDecls target userDecls roots examples synthDecls synthResults =
  let allUser = userDecls ++ synthDecls
  let userNames = funNamesOf allUser
  let livePrelude =
    if programIsCore userDecls then [] else dropShadowedExp userNames coreDecls
  let rootId = singleRootId roots target
  let elaborated = elaborateOne runtimeDecls livePrelude (rootId, allUser)
  let env = evalOneWith (testCapableExterns ()) [] ("__main__", elaborated)
  buildDetailsFrom (Ok (renderExamples env examples)) synthResults examples

-- DRIVER-COLLAPSE Phase 1+3 note on the dict-set: the old `coreDictNames`
-- externally-built dict-set (preludeReturnPosDictNames ++ constrainedSigNames, with
-- arg-position helpers excluded to keep the `neq`-hang closed) is gone — the
-- migrated runSingle/runPropsSingle route through elaborateModules, which OWNS the
-- equivalent return-position dict-set via its own `moduleDictNames`.  The
-- `medaka test stdlib/core.mdk` canary guards the neq-hang.

-- Mirror of compiler/resolve.mdk's
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

-- Multi-module path: load the module graph, inject synth into the root module,
-- elaborate across modules, eval (root env carries the __dt_i__ bindings).
runMulti : List Decl ->
  List Decl ->
  String ->
  List Decl ->
  List String ->
  List Example ->
  List Decl ->
  List (Result String (List Decl)) ->
  <IO> RunResult
runMulti runtimeDecls coreDecls target _userDecls roots examples synthDecls synthResults =
  match loadProgram target roots
    Err e => buildDetailsFrom (Err e) synthResults examples
    Ok mods =>
      let injected = injectIntoRoot target synthDecls (map desugarPair mods)
      let elaborated = elaborateModulesMangled runtimeDecls coreDecls injected
      let env =
        evalModulesWith
          (testCapableExterns ())
          (fst elaborated)
          (snd elaborated)
      buildDetailsFrom (Ok (renderExamples env examples)) synthResults examples

desugarPair : (String, List Decl) -> (String, List Decl)
desugarPair (mid, p) = (mid, desugar p)

-- Append synth decls to the ROOT (last) module in the loaded list.  The
-- loader returns modules in dependency-first order, so the entry (target)
-- is always last.  Using the last module avoids having to recompute the
-- module id from the target path + roots (which is how the loader keyed it),
-- making the injection robust to both relative and absolute target paths and
-- to nested module ids like "lib.probe" vs bare ids like "probe".
--
-- ⚠️ This is the SAME hazard `singleRootId`/`canonicalPathId` (ARCH E-5, near
-- runSingle above) exists to close, not a contradiction of it.  This function
-- sidesteps recomputation entirely (position, not a recomputed id) because it
-- must MATCH an id the loader ALREADY minted for the multi-module entry
-- (`loadProgramFilesE`'s own `moduleIdOfPath roots entry`, first-root — a
-- recompute via `canonicalModId`'s last-root convention would NOT match it, and
-- a mismatch here means injecting into the wrong module or none).  `runSingle`'s
-- `rootId` has no existing id to match — it MINTS the single node's only id — so
-- recomputing it via the loader's own dependency-resolution convention
-- (`canonicalPathId`) is what makes it agree with how a SIBLING target's graph
-- load would independently canonicalize this same file, which is the actual
-- #1223 property. Different problem, different function, not a disagreement.
injectIntoRoot : String ->
  List Decl ->
  List (String, List Decl) ->
  List (String, List Decl)
injectIntoRoot _ synthDecls mods = injectIntoLast synthDecls mods

injectIntoLast : List Decl ->
  List (String, List Decl) ->
  List (String, List Decl)
injectIntoLast _ [] = []
injectIntoLast synthDecls [(mid, decls)] = [(mid, decls ++ synthDecls)]
injectIntoLast synthDecls (x :: rest) = x :: injectIntoLast synthDecls rest

-- ── doctest reporting ─────────────────────────────────────────────────────

-- The per-example lines and the `(F failed, E errors)` suffix moved to
-- `tools/doctest.mdk` (#81 Stage 2), beside `RunResult`: a native engine must
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
-- name (not position, unlike (b)'s `test "…"` fix): the packet scopes props
-- to the same name-matched mechanism `test "…"` used to use, not to (b)'s
-- duplicate-name repair — a duplicate prop name is not this slice's problem.
propLineTests : String -> List (String, Int)
propLineTests tsrc = collectPropLines (desugar (parseLocated tsrc))

collectPropLines : List Decl -> List (String, Int)
collectPropLines [] = []
collectPropLines ((DProp _ name _ body) :: rest) =
  (name, exprLineLocal body) :: collectPropLines rest
collectPropLines (_ :: rest) = collectPropLines rest

-- Peel a transparent ELoc wrapper to recover a body's source line. Intentional
-- cross-file duplicate of `test_runner.mdk`'s private (unexported) `exprLine`
-- — tiny helper, not worth exporting across a module boundary for one caller.
-- lint-disable-next-line rule-duplicate-body
exprLineLocal : Expr -> Int
exprLineLocal (ELoc (Loc _ l _ _ _) _) = l
exprLineLocal (EApp f _) = exprLineLocal f
exprLineLocal (EAnnot e _) = exprLineLocal e
exprLineLocal (EHeadAnnot e _) = exprLineLocal e
exprLineLocal _ = 0

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
    (coreE, modulesE, _) => mangleCtorCollisionsPair (coreE, modulesE)

runProps : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Int ->
  Option String ->
  <IO> Bool
runProps runtimeDecls coreDecls target tsrc userDecls roots cases filterOpt
  | not (hasProps userDecls) = True
  | hasUseDecls userDecls =
    runPropsMulti
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      cases
      filterOpt
  | otherwise =
    runPropsSingle
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      cases
      filterOpt

-- Single-file (no-import) prop path, DRIVER-COLLAPSE Phase 1+3: same multi-module
-- path as runPropsMulti, with the degenerate 1-module list [(rootId, userDecls)].
-- livePrelude passed SEPARATE (programIsCore ⇒ []); elaborateModules owns the
-- dict-set.
-- evalModulesRootEnv exposes prelude globals (eq/compare) the prop bodies need, and
-- the prop bodies themselves are pulled from the ELABORATED root module (dict-passed
-- call sites) — keyed by the loader-derived `rootId` (ARCH E-5, #1521/#1223) — so
-- the file's own `=>`-constrained fns (set's `fromList`/`wellFormed`) get their
-- leading dict argument, mirroring runPropsMulti's elaboratedRootProps (which
-- inferPropBodies typed in-module).
runPropsSingle : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Int ->
  Option String ->
  <IO> Bool
runPropsSingle runtimeDecls coreDecls target tsrc userDecls roots cases filterOpt =
  let userNames = funNamesOf userDecls
  let livePrelude =
    if programIsCore userDecls then [] else dropShadowedExp userNames coreDecls
  let rootId = singleRootId roots target
  let elaborated =
    elaborateModulesMangled runtimeDecls livePrelude [(rootId, userDecls)]
  let env =
    evalModulesRootEnvWith
      (testCapableExterns ())
      (fst elaborated)
      (snd elaborated)
  let rootProps = match lookupModuleDecls rootId (snd elaborated)
    Some decls => decls
    None => userDecls
  runAllProps cases filterOpt target (propLineTests tsrc) env rootProps

runPropsMulti : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Int ->
  Option String ->
  <IO> Bool
runPropsMulti runtimeDecls coreDecls target tsrc userDecls roots cases filterOpt =
  match loadProgram target roots
    Err e =>
      let _ = ePutStrLn e
      False
    Ok mods =>
      let elaborated =
        elaborateModulesMangled runtimeDecls coreDecls (map desugarPair mods)
      let env =
        evalModulesRootEnvWith
          (testCapableExterns ())
          (fst elaborated)
          (snd elaborated)
      let rootProps = elaboratedRootProps target (snd elaborated) userDecls
      runAllProps cases filterOpt target (propLineTests tsrc) env rootProps
-- DRIVER-COLLAPSE Phase 2: the eval-dict layer now promotes the file's own
-- `=>`-constrained fns (set's `wellFormed`/`fromList`, etc.), so the bindings in
-- [env] take a leading dict ARGUMENT.  A prop body calls those fns, so its call
-- sites must carry the matching dict argument — i.e. the bodies must be the
-- ELABORATED (marked + dict-passed) ones, NOT raw `userDecls`.  Pull the props
-- from the elaborated root module (mirrors how runMulti's doctest synth bodies
-- are elaborated in-tree); raw bodies would under-apply the now-dict-passed call
-- and `force` a partial closure → not VBool → every prop "fails" (set's
-- `fromList []` reported ill-formed).

-- The prop decls to evaluate: the elaborated root module's props (dict-passed call
-- sites) when the loader kept a module whose id matches the target's basename;
-- otherwise fall back to the raw userDecls (preserves the pre-Phase-2 behaviour for
-- any path where the root module isn't separately present).
-- The root module is the LAST in the list (dependency-first order — entry is last).
elaboratedRootProps : String ->
  List (String, List Decl) ->
  List Decl ->
  List Decl
elaboratedRootProps _ modules userDecls = match lastModule modules
  Some decls => decls
  None => userDecls

lastModule : List (String, List Decl) -> Option (List Decl)
lastModule [] = None
lastModule [(_, decls)] = Some decls
lastModule (_ :: rest) = lastModule rest

lookupModuleDecls : String -> List (String, List Decl) -> Option (List Decl)
lookupModuleDecls _ [] = None
lookupModuleDecls rootId ((mid, decls) :: rest)
  | mid == rootId = Some decls
  | otherwise = lookupModuleDecls rootId rest

-- ── test phase (Phase 127 restored 2026-07-11) ───────────────────────────────
-- Symmetric with the prop phase: only runs (and prints) if the file declares
-- `test "…"` decls.  Each body is evaluated to an `Expectation` VALUE (panics are
-- NOT caught — a genuinely-crashing body aborts the run), and the pass/fail is
-- reported with the SAME shape as the doctest phase (RunResult/ExResult + loc +
-- summary + exit code), per P0-6.  Discovery routes through the same multi-module
-- vs single-file split as the prop phase, and — like runPropsMulti — pulls the
-- DTest bodies from the ELABORATED root module so their `expectEqual`/… call sites
-- carry the dict argument (`import test`'s constrained assertions).

runTestDecls : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Option String ->
  <IO> Bool
runTestDecls runtimeDecls coreDecls target tsrc userDecls roots filterOpt
  | not (hasTests userDecls) = True
  | hasUseDecls userDecls =
    runTestDeclsMulti
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      filterOpt
  | otherwise =
    runTestDeclsSingle
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      filterOpt

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

-- Keyed by the loader-derived `rootId` (ARCH E-5, #1521/#1223), not the retired
-- synthetic `"__user__"` literal — see the ARCH E-5 note near runSingle above.
runTestDeclsSingle : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Option String ->
  <IO> Bool
runTestDeclsSingle runtimeDecls coreDecls target tsrc userDecls roots filterOpt =
  let userNames = funNamesOf userDecls
  let livePrelude =
    if programIsCore userDecls then [] else dropShadowedExp userNames coreDecls
  let rootId = singleRootId roots target
  let elaborated =
    elaborateModulesMangled runtimeDecls livePrelude [(rootId, userDecls)]
  let env =
    evalModulesRootEnvWith
      (testCapableExterns ())
      (fst elaborated)
      (snd elaborated)
  let rootTests = match lookupModuleDecls rootId (snd elaborated)
    Some decls => decls
    None => userDecls
  reportTests
    target
    env
    (filterTestsByName
      filterOpt
      (attachRawLines (testLineTests tsrc) (collectTests rootTests)))

runTestDeclsMulti : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Option String ->
  <IO> Bool
runTestDeclsMulti runtimeDecls coreDecls target tsrc userDecls roots filterOpt =
  match loadProgram target roots
    Err e =>
      let _ = ePutStrLn e
      False
    Ok mods =>
      let elaborated =
        elaborateModulesMangled runtimeDecls coreDecls (map desugarPair mods)
      let env =
        evalModulesRootEnvWith
          (testCapableExterns ())
          (fst elaborated)
          (snd elaborated)
      let rootTests = elaboratedRootProps target (snd elaborated) userDecls
      reportTests
        target
        env
        (filterTestsByName
          filterOpt
          (attachRawLines (testLineTests tsrc) (collectTests rootTests)))

-- The elaborated (dict-passed) body loses its leading ELoc (the marker rewrites
-- the leftmost method EVar into a dict node), so take each test's line from the
-- RAW parsed decls.
--
-- #2295 (b): matched by POSITION, not by test NAME. The old name match
-- collapsed two same-named `test "…"` decls onto one line and reported line 0
-- for any name it failed to find (which could also happen silently on a
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

-- Reuses the doctest reporting SHAPE (`ok`/`FAIL <f>:<line>: <name>`, then the
-- `<f>: P/T passed[ (F failed, E errors)]` summary + exit code, P0-6).  Like the
-- prop phase, each result is printed AS its body is evaluated (not batched), so a
-- body that aborts the run still leaves the tests that already passed on screen.
-- Returns True iff every test passed.
reportTests : String ->
  List (String, Value e) ->
  List (String, Int, Expr) ->
  <IO> Bool
reportTests target env tests =
  let _ = putStrLn ("running tests in " ++ target)
  let (passed, failed, errors) = runTestLoop target env tests 0 0 0
  let total = passed + failed + errors
  let _ =
    putStr "\n\{target}: \{intToString passed}/\{intToString total} passed"
  let _ = putStr (testFailSuffix failed errors)
  let _ = putStr "\n"
  failed == 0 && errors == 0

runTestLoop : String ->
  List (String, Value e) ->
  List (String, Int, Expr) ->
  Int ->
  Int ->
  Int ->
  <IO> (Int, Int, Int)
runTestLoop _ _ [] passed failed errors = (passed, failed, errors)
runTestLoop target env ((name, line, body) :: rest) passed failed errors =
  let loc = "\{target}:\{intToString line}"
  -- #2293: name the test BEFORE evaluating its body. Panics are uncatchable
  -- by design (settled: isolation only, never catchability), so this print is
  -- the runner's only chance to attribute a mid-run process death — if the
  -- process dies inside `runOneTest` below, this line is the last thing on
  -- stdout, and the disappearance of every test after it is explained rather
  -- than mysterious.
  let _ = putStrLn "  running \{loc}: \{name}"
  match runOneTest env body
    Pass =>
      let _ = putStrLn "  ok   \{loc}: \{name}"
      runTestLoop target env rest (passed + 1) failed errors
    Fail msg _ =>
      let _ = putStrLn "  FAIL \{loc}: \{name}"
      let _ = putStrLn ("       " ++ msg)
      runTestLoop target env rest passed (failed + 1) errors
    Errored msg =>
      let _ = putStrLn "  FAIL \{loc}: \{name}"
      let _ = putStrLn ("       " ++ msg)
      runTestLoop target env rest passed failed (errors + 1)

testFailSuffix : Int -> Int -> String
testFailSuffix failed errors
  | failed > 0 || errors > 0 =
    " (\{intToString failed} failed, \{intToString errors} errors)"
  | otherwise = ""

-- ── structured (non-printing) report — for `medaka mcp`'s medaka_test (#252) ──
-- Returns the doctest RunResult (per-example ExResult details) plus a PropResult
-- per property for `target`, WITHOUT printing anything: the human `medaka test`
-- path (runTest/driveAll above) is left entirely intact.  It reuses the SAME
-- drivers — runChosen for doctests, the prop single/multi split for props — so
-- what medaka_test decides can never diverge from what `medaka test` would
-- decide, only how it is reported.  The prelude sources are parsed+desugared
-- here (mirroring runTest), and the module-search roots are derived exactly as
-- the CLI does (entry dir + project root, then stdlib).
--
-- #1443: routed through the SAME `typecheckGateResult`/`doctestGate` decision
-- `runTest` gates on, so a module that fails the type check can no longer
-- report a green (empty, `"ok":true`) summary here — the located type-error
-- text is returned as the first element instead, and neither doctests nor
-- props run (mirrors `runTest`, which never reaches `driveAll` on a gate
-- failure).  A correctly EXEMPTED module (`test`/`prop`-bearing, no doctest)
-- still runs doctests+props normally with `None` here — same as `doctestGate`
-- exempts it for the CLI — just without the CLI's stderr notice, since this
-- path has no stderr channel of its own (see `typecheckGateResult`).
--
-- ⚠️ Results are under the INTERPRETER (eval) — a native-only miscompile is
-- invisible here (see #81); the CALLER must present them as "passes under eval",
-- never an unqualified pass.
--
-- #2295 (d): the return tuple carries a 4th element, the `test "…"` phase's
-- structured results (`testDeclsReport`, above) — §4 of this slice's packet
-- licenses extending this shape (not reverting it) — plus a 5th, whether the
-- module was exempted from typechecking (`typecheckExempt`, F7: #1680/#1443's
-- skip marker used to be human-arm-stderr-only, invisible to `--json`/MCP).
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
  <IO> (Option String, List (Engine, RunResult), List PropResult, List (String, Int, ExResult), Bool)
runTestReport engines runtimeSrc coreSrc target tsrc stdlibDir cases filterOpt includeTestDecls =
  -- S-1/#2234 (F-converge): content-keyed prelude memo (see `runTest` above).
  let runtimeDecls = desugaredPrelude runtimeSrc
  let coreDecls = desugaredPrelude coreSrc
  let roots = entrySearchRoots (dirOf target) ++ [stdlibDir]
  let userDecls = desugar (parse tsrc)
  match typecheckGateResult target roots runtimeSrc coreSrc tsrc userDecls
    Some errText => (Some errText, [], [], [], False)
    None =>
      let doctestRuns =
        doctestReport
          engines
          runtimeDecls
          coreDecls
          target
          tsrc
          userDecls
          roots
          filterOpt
      let propResults =
        propsReport
          runtimeDecls
          coreDecls
          target
          tsrc
          userDecls
          roots
          cases
          filterOpt
      let testResults =
        if includeTestDecls then
          testDeclsReport
            runtimeDecls
            coreDecls
            target
            tsrc
            userDecls
            roots
            filterOpt
        else
          []
      (
        None,
        doctestRuns,
        propResults,
        testResults,
        typecheckExempt target userDecls tsrc,
      )

-- Doctest phase as pure data: extraction + runChosenOn per requested engine,
-- minus reportDoctests' printing.  A file with zero doctests yields the empty
-- RunResult for every engine.  Positionally tagged by engine so a caller
-- (e.g. `medaka mcp`'s medaka_test) can derive an "engine" label instead of
-- hardcoding one.  `filterOpt` mirrors `runDoctests`' `filterExamplesByName`
-- (F1: `medaka test --json --filter` was silently ignoring this) — MCP's
-- medaka_test still passes `None` (unchanged behavior, #2295 scoped to CLI).
doctestReport : List Engine ->
  List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Option String ->
  <IO> List (Engine, RunResult)
doctestReport engines runtimeDecls coreDecls target tsrc userDecls roots filterOpt =
  let examples =
    filterExamplesByName filterOpt (extractExamples (collectComments tsrc))
  match examples
    [] => emptyDoctestRuns engines
    _ =>
      let synthResults = buildSynthResults examples
      let synthDecls = buildSynthDecls synthResults
      doctestReportGo
        engines
        runtimeDecls
        coreDecls
        target
        tsrc
        userDecls
        roots
        examples
        synthDecls
        synthResults

emptyDoctestRuns : List Engine -> List (Engine, RunResult)
emptyDoctestRuns [] = []
emptyDoctestRuns (e :: rest) =
  (e, RunResult 0 0 0 0 []) :: emptyDoctestRuns rest

doctestReportGo : List Engine ->
  List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  List Example ->
  List Decl ->
  List (Result String (List Decl)) ->
  <IO> List (Engine, RunResult)
doctestReportGo [] _ _ _ _ _ _ _ _ _ = []
doctestReportGo (e :: rest) runtimeDecls coreDecls target tsrc userDecls roots examples synthDecls synthResults =
  (
      e,
      runChosenOn
        e
        runtimeDecls
        coreDecls
        target
        tsrc
        userDecls
        roots
        examples
        synthDecls
        synthResults,
    )
    :: doctestReportGo
      rest
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      examples
      synthDecls
      synthResults

-- Prop phase as pure data: same single-file/multi-module split as runProps, but
-- calling runAllPropsResults (silent) instead of runAllProps (printing).
-- `cases`/`filterOpt` mirror `runProps`' own parameters (F1: `medaka test
-- --json --cases`/`--filter` were silently ignored) — MCP's medaka_test still
-- passes `(100, None)` (unchanged behavior, #2295 is scoped to the CLI).
propsReport : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Int ->
  Option String ->
  <IO> List PropResult
propsReport runtimeDecls coreDecls target tsrc userDecls roots cases filterOpt
  | not (hasProps userDecls) = []
  | hasUseDecls userDecls =
    propsReportMulti
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      cases
      filterOpt
  | otherwise =
    propsReportSingle
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      cases
      filterOpt

-- Keyed by the loader-derived `rootId` (ARCH E-5, #1521/#1223), not the retired
-- synthetic `"__user__"` literal — see the ARCH E-5 note near runSingle above.
propsReportSingle : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Int ->
  Option String ->
  <IO> List PropResult
propsReportSingle runtimeDecls coreDecls target tsrc userDecls roots cases filterOpt =
  let userNames = funNamesOf userDecls
  let livePrelude =
    if programIsCore userDecls then [] else dropShadowedExp userNames coreDecls
  let rootId = singleRootId roots target
  let elaborated =
    elaborateModulesMangled runtimeDecls livePrelude [(rootId, userDecls)]
  let env =
    evalModulesRootEnvWith
      (testCapableExterns ())
      (fst elaborated)
      (snd elaborated)
  let rootProps = match lookupModuleDecls rootId (snd elaborated)
    Some decls => decls
    None => userDecls
  runAllPropsResults cases filterOpt (propLineTests tsrc) env rootProps

propsReportMulti : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Int ->
  Option String ->
  <IO> List PropResult
propsReportMulti runtimeDecls coreDecls target tsrc userDecls roots cases filterOpt =
  match loadProgram target roots
    Err _ => []
    Ok mods =>
      let elaborated =
        elaborateModulesMangled runtimeDecls coreDecls (map desugarPair mods)
      let env =
        evalModulesRootEnvWith
          (testCapableExterns ())
          (fst elaborated)
          (snd elaborated)
      let rootProps = elaboratedRootProps target (snd elaborated) userDecls
      runAllPropsResults cases filterOpt (propLineTests tsrc) env rootProps

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
testDeclsReport : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Option String ->
  <IO> List (String, Int, ExResult)
testDeclsReport runtimeDecls coreDecls target tsrc userDecls roots filterOpt
  | not (hasTests userDecls) = []
  | hasUseDecls userDecls =
    testDeclsReportMulti
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      filterOpt
  | otherwise =
    testDeclsReportSingle
      runtimeDecls
      coreDecls
      target
      tsrc
      userDecls
      roots
      filterOpt

testDeclsReportSingle : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Option String ->
  <IO> List (String, Int, ExResult)
testDeclsReportSingle runtimeDecls coreDecls target tsrc userDecls roots filterOpt =
  let userNames = funNamesOf userDecls
  let livePrelude =
    if programIsCore userDecls then [] else dropShadowedExp userNames coreDecls
  let rootId = singleRootId roots target
  let elaborated =
    elaborateModulesMangled runtimeDecls livePrelude [(rootId, userDecls)]
  let env =
    evalModulesRootEnvWith
      (testCapableExterns ())
      (fst elaborated)
      (snd elaborated)
  let rootTests = match lookupModuleDecls rootId (snd elaborated)
    Some decls => decls
    None => userDecls
  runTestsCollect
    env
    (filterTestsByName
      filterOpt
      (attachRawLines (testLineTests tsrc) (collectTests rootTests)))

testDeclsReportMulti : List Decl ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  List String ->
  Option String ->
  <IO> List (String, Int, ExResult)
testDeclsReportMulti runtimeDecls coreDecls target tsrc userDecls roots filterOpt =
  match loadProgram target roots
    Err _ => []
    Ok mods =>
      let elaborated =
        elaborateModulesMangled runtimeDecls coreDecls (map desugarPair mods)
      let env =
        evalModulesRootEnvWith
          (testCapableExterns ())
          (fst elaborated)
          (snd elaborated)
      let rootTests = elaboratedRootProps target (snd elaborated) userDecls
      runTestsCollect
        env
        (filterTestsByName
          filterOpt
          (attachRawLines (testLineTests tsrc) (collectTests rootTests)))

runTestsCollect : List (String, Value e) ->
  List (String, Int, Expr) ->
  <IO> List (String, Int, ExResult)
runTestsCollect _ [] = []
runTestsCollect env ((name, line, body) :: rest) =
  (name, line, runOneTest env body) :: runTestsCollect env rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DData" false) (mem "DInterface" false) (mem "DProp" false) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseResult" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgram" false) (mem "entrySearchRoots" false) (mem "canonicalPathId" false) (mem "readDeps" false) (mem "findProjectRootOrSelf" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "readPreludeFile" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateOne" false) (mem "elaborateModules" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "mangleCtorCollisionsPair" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" false) (mem "evalOneWith" false) (mem "evalModulesWith" false) (mem "evalModulesRootEnvWith" false) (mem "testCapableExterns" false) (mem "funNamesOf" false) (mem "dropShadowedExp" false) (mem "lookupBinding" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" true) (mem "Engine" true) (mem "engineName" false) (mem "extractExamples" false) (mem "buildSynthResults" false) (mem "buildSynthDecls" false) (mem "buildDetailsFrom" false) (mem "doctestFailSuffix" false) (mem "hasUseDecls" false) (mem "printDoctestDetails" false) (mem "runDetails" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "synthName" false))))
(DUse false (UseGroup ("tools" "native_doctest") ((mem "runNativeDoctests" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "runAllProps" false) (mem "hasProps" false) (mem "runAllPropsResults" false) (mem "PropResult" false))))
(DUse false (UseGroup ("tools" "test_runner") ((mem "collectTests" false) (mem "runOneTest" false) (mem "hasTests" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeProject" false) (mem "analyzeLocated" false) (mem "readDiagSrc" false) (mem "ppDiagCliSrc" false) (mem "ppDiagCliLines" false) (mem "srcLinesArr" false) (mem "parseErrDiag" false) (mem "Diag" false) (mem "diagIsError" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "joinNl" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "endsWith" false) (mem "splitOnChar" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DTypeSig false "substringMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substringMatch" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "rootsOrDefault" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "rootsOrDefault" ((PVar "target") (PList)) (EListLit (EApp (EVar "dirOf") (EVar "target"))))
(DFunDef false "rootsOrDefault" (PWild (PVar "roots")) (EVar "roots"))
(DTypeSig true "runTest" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTest" ((PVar "engines") (PVar "runtimeP") (PVar "coreP") (PVar "target") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EMatch (EApp (EVar "readPreludeFile") (EVar "runtimeP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "coreP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EVar "parseErrDiag") (EVar "target")) (EVar "e"))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestGate") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "userDecls")) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "errText")))) (DoExpr (EVar "False")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveAll") (EVar "engines")) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")))))))))))))))
(DTypeSig false "typecheckExempt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "typecheckExempt" ((PVar "target") (PVar "userDecls") (PVar "tsrc")) (EIf (EApp (EVar "isNonEmptyL") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (EVar "False") (EIf (EApp (EVar "isNewVehiclePath") (EVar "target")) (EVar "False") (EIf (EVar "otherwise") (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EApp (EVar "hasTests") (EVar "userDecls"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isNewVehiclePath" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "isNewVehiclePath" ((PVar "target")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "target")) (EApp (EVar "hasVehicleSegment") (EApp (EVar "canonicalizePath") (EVar "target"))) (EVar "False")))
(DTypeSig false "hasVehicleSegment" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasVehicleSegment" ((PVar "path")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (ELam ((PVar "seg")) (EBinOp "||" (EBinOp "==" (EVar "seg") (ELit (LString "compiler"))) (EBinOp "==" (EVar "seg") (ELit (LString "stdlib")))))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path")))))
(DTypeSig false "doctestGate" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "doctestGate" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "userDecls")) (EIf (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckSkipNotice") (EVar "target")) (EVar "userDecls")))) (DoExpr (EVar "None"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "userDecls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "typecheckGateResult" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "typecheckGateResult" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "userDecls")) (EIf (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc")) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "userDecls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "typecheckErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "typecheckErrors" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "userDecls")) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EVar "projectTypeErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "rsrc")) (EVar "csrc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "singleFileTypeErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "singleFileTypeErrors" ((PVar "target") (PVar "tsrc") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EApp (EApp (EApp (EVar "analyzeLocated") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs")))))))))
(DTypeSig false "projectTypeErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "projectTypeErrors" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "True")) (EListLit)) (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false (PVar "rendered") (EApp (EApp (EVar "flatMap") (EVar "renderFileErrors")) (EVar "triples"))) (DoExpr (EMatch (EVar "rendered") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "rendered"))))))))
(DTypeSig false "renderFileErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderFileErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EVar "diags"))))
(DTypeSig false "typecheckGateFail" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typecheckGateFail" ((PVar "target") (PVar "errText")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type error in ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString " — `medaka test` requires it to `medaka check` first:\n"))) (EApp (EVar "display") (EVar "errText"))) (ELit (LString ""))))
(DTypeSig false "typecheckSkipNotice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "typecheckSkipNotice" ((PVar "target") (PVar "userDecls")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "note: typechecking was skipped for ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString "\n  reason: the module declares "))) (EApp (EVar "display") (EApp (EVar "skipReasonDecls") (EVar "userDecls")))) (ELit (LString " and no doctests, so `medaka test` exempts it from the type checker (issue #1229) — those phases exist to exercise eval on constructs `medaka check` rejects.\n  a runtime error below may therefore be an uncaught TYPE error.\n  to type-check it: medaka check "))) (EApp (EVar "display") (EVar "target"))) (ELit (LString ""))))
(DTypeSig false "skipReasonDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "skipReasonDecls" ((PVar "userDecls")) (EIf (EBinOp "&&" (EApp (EVar "hasTests") (EVar "userDecls")) (EApp (EVar "hasProps") (EVar "userDecls"))) (ELit (LString "`test \"…\"` and `prop \"…\"` decls")) (EIf (EApp (EVar "hasTests") (EVar "userDecls")) (ELit (LString "`test \"…\"` decls")) (EIf (EVar "otherwise") (ELit (LString "`prop \"…\"` decls")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "driveAll" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "driveAll" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProps") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDecls") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk")))))
(DTypeSig false "filterExamplesByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyCon "Example")))))
(DFunDef false "filterExamplesByName" ((PCon "None") (PVar "examples")) (EVar "examples"))
(DFunDef false "filterExamplesByName" ((PCon "Some" (PVar "sub")) (PVar "examples")) (EApp (EApp (EVar "filterList") (ELam ((PVar "ex")) (EApp (EApp (EVar "substringMatch") (EVar "sub")) (EApp (EVar "exampleInput") (EVar "ex"))))) (EVar "examples")))
(DTypeSig false "runDoctests" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "runDoctests" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running doctests in ")) (EVar "target")))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoExpr (EMatch (EVar "examples") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  (no doctests found)")))) (DoExpr (EVar "True")))) (arm PWild () (EBlock (DoLet false false (PVar "synthResults") (EApp (EVar "buildSynthResults") (EVar "examples"))) (DoLet false false (PVar "synthDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEngines") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")))))))))
(DTypeSig false "runEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool")))))))))))))
(DFunDef false "runEngines" ((PList (PVar "e")) (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EBlock (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))) (DoExpr (EApp (EApp (EVar "reportDoctests") (EVar "target")) (EVar "result")))))
(DFunDef false "runEngines" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEnginesTagged") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")))
(DTypeSig false "runEnginesTagged" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool")))))))))))))
(DFunDef false "runEnginesTagged" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EVar "True"))
(DFunDef false "runEnginesTagged" ((PCons (PVar "e") (PVar "rest")) (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "-- ")) (EApp (EVar "display") (EApp (EVar "engineName") (EVar "e")))) (ELit (LString " --"))))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))) (DoLet false false (PVar "ok") (EApp (EApp (EVar "reportDoctests") (EVar "target")) (EVar "result"))) (DoLet false false (PVar "restOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEnginesTagged") (EVar "rest")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))) (DoExpr (EBinOp "&&" (EVar "ok") (EVar "restOk")))))
(DTypeSig true "runChosenOn" (TyFun (TyCon "Engine") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))))
(DFunDef false "runChosenOn" ((PCon "EngInterp") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "_tsrc") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosen") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")))
(DFunDef false "runChosenOn" ((PCon "EngNative") (PVar "_runtimeDecls") (PVar "_coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "_roots") (PVar "examples") (PVar "_synthDecls") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EVar "runNativeDoctests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))
(DTypeSig false "runChosen" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))
(DFunDef false "runChosen" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "renderExamples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderExamples" ((PVar "env") (PVar "examples")) (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (ELit (LInt 0))) (EVar "examples")))
(DTypeSig false "renderExamplesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "renderExamplesGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "renderExamplesGo" ((PVar "env") (PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "renderOneExample") (EVar "env")) (EVar "i")) (EVar "ex")) (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "renderOneExample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderOneExample" ((PVar "env") (PVar "i") (PVar "ex")) (EMatch (EApp (EApp (EVar "lookupBinding") (EApp (EVar "synthName") (EVar "i"))) (EVar "env")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "could not evaluate: ")) (EApp (EVar "exampleInput") (EVar "ex"))))) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))))))
(DTypeSig true "singleRootId" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "singleRootId" ((PVar "roots") (PVar "target")) (EBlock (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "target"))))) (DoExpr (EApp (EApp (EApp (EVar "canonicalPathId") (EVar "deps")) (EVar "roots")) (EVar "target")))))
(DTypeSig false "runSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))
(DFunDef false "runSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EBlock (DoLet false false (PVar "allUser") (EBinOp "++" (EVar "userDecls") (EVar "synthDecls"))) (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "allUser"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateOne") (EVar "runtimeDecls")) (EVar "livePrelude")) (ETuple (EVar "rootId") (EVar "allUser")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalOneWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EListLit)) (ETuple (ELit (LString "__main__")) (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))
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
(DTypeSig false "runMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))
(DFunDef false "runMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "_userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Err") (EVar "e"))) (EVar "synthResults")) (EVar "examples"))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "injected") (EApp (EApp (EApp (EVar "injectIntoRoot") (EVar "target")) (EVar "synthDecls")) (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "injected"))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "p"))))
(DTypeSig false "injectIntoRoot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "injectIntoRoot" (PWild (PVar "synthDecls") (PVar "mods")) (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EVar "mods")))
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
(DFunDef false "collectPropLines" ((PCons (PCon "DProp" PWild (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "exprLineLocal") (EVar "body"))) (EApp (EVar "collectPropLines") (EVar "rest"))))
(DFunDef false "collectPropLines" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectPropLines") (EVar "rest")))
(DTypeSig false "exprLineLocal" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprLineLocal" ((PCon "ELoc" (PCon "Loc" PWild (PVar "l") PWild PWild PWild) PWild)) (EVar "l"))
(DFunDef false "exprLineLocal" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "exprLineLocal") (EVar "f")))
(DFunDef false "exprLineLocal" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "exprLineLocal") (EVar "e")))
(DFunDef false "exprLineLocal" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "exprLineLocal") (EVar "e")))
(DFunDef false "exprLineLocal" (PWild) (ELit (LInt 0)))
(DTypeSig false "elaborateModulesMangled" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "elaborateModulesMangled" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild) () (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE"))))))
(DTypeSig false "runProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "runProps" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EVar "True") (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropsMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropsSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "runPropsSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "runPropsSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runAllProps") (EVar "cases")) (EVar "filterOpt")) (EVar "target")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EVar "env")) (EVar "rootProps")))))
(DTypeSig false "runPropsMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "runPropsMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runAllProps") (EVar "cases")) (EVar "filterOpt")) (EVar "target")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EVar "env")) (EVar "rootProps")))))))
(DTypeSig false "elaboratedRootProps" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "elaboratedRootProps" (PWild (PVar "modules") (PVar "userDecls")) (EMatch (EApp (EVar "lastModule") (EVar "modules")) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls"))))
(DTypeSig false "lastModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "lastModule" ((PList)) (EVar "None"))
(DFunDef false "lastModule" ((PList (PTuple PWild (PVar "decls")))) (EApp (EVar "Some") (EVar "decls")))
(DFunDef false "lastModule" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModule") (EVar "rest")))
(DTypeSig false "lookupModuleDecls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lookupModuleDecls" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupModuleDecls" ((PVar "rootId") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "mid") (EVar "rootId")) (EApp (EVar "Some") (EVar "decls")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runTestDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestDecls" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EVar "True") (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "testLineTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "testLineTests" ((PVar "tsrc")) (EApp (EVar "collectTests") (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "tsrc")))))
(DTypeSig false "filterTestsByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))
(DFunDef false "filterTestsByName" ((PCon "None") (PVar "tests")) (EVar "tests"))
(DFunDef false "filterTestsByName" ((PCon "Some" (PVar "sub")) (PVar "tests")) (EApp (EApp (EVar "filterList") (ELam ((PVar "t")) (EApp (EApp (EVar "substringMatch") (EVar "sub")) (EApp (EVar "fst3") (EVar "t"))))) (EVar "tests")))
(DTypeSig false "fst3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "a")))
(DFunDef false "fst3" ((PTuple (PVar "a") PWild PWild)) (EVar "a"))
(DTypeSig false "runTestDeclsSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestDeclsSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EApp (EVar "reportTests") (EVar "target")) (EVar "env")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests"))))))))
(DTypeSig false "runTestDeclsMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestDeclsMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EApp (EVar "reportTests") (EVar "target")) (EVar "env")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests"))))))))))
(DTypeSig false "attachRawLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))
(DFunDef false "attachRawLines" (PWild (PList)) (EListLit))
(DFunDef false "attachRawLines" ((PList) (PCons (PTuple (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (ELit (LInt 0)) (EVar "body")) (EApp (EApp (EVar "attachRawLines") (EListLit)) (EVar "rest"))))
(DFunDef false "attachRawLines" ((PCons (PTuple PWild (PVar "l") PWild) (PVar "rawRest")) (PCons (PTuple (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "l") (EVar "body")) (EApp (EApp (EVar "attachRawLines") (EVar "rawRest")) (EVar "rest"))))
(DTypeSig false "reportTests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "reportTests" ((PVar "target") (PVar "env") (PVar "tests")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running tests in ")) (EVar "target")))) (DoLet false false (PTuple (PVar "passed") (PVar "failed") (PVar "errors")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EVar "passed") (EVar "failed")) (EVar "errors"))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " passed"))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EVar "testFailSuffix") (EVar "failed")) (EVar "errors")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EVar "failed") (ELit (LInt 0))) (EBinOp "==" (EVar "errors") (ELit (LInt 0)))))))
(DTypeSig false "runTestLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))))))))
(DFunDef false "runTestLoop" (PWild PWild (PList) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EVar "errors")))
(DFunDef false "runTestLoop" ((PVar "target") (PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest")) (PVar "passed") (PVar "failed") (PVar "errors")) (EBlock (DoLet false false (PVar "loc") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  running ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EMatch (EApp (EApp (EVar "runOneTest") (EVar "env")) (EVar "body")) (arm (PCon "Pass") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ok   ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EBinOp "+" (EVar "passed") (ELit (LInt 1)))) (EVar "failed")) (EVar "errors"))))) (arm (PCon "Fail" (PVar "msg") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EVar "passed")) (EBinOp "+" (EVar "failed") (ELit (LInt 1)))) (EVar "errors"))))) (arm (PCon "Errored" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EVar "passed")) (EVar "failed")) (EBinOp "+" (EVar "errors") (ELit (LInt 1)))))))))))
(DTypeSig false "testFailSuffix" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "testFailSuffix" ((PVar "failed") (PVar "errors")) (EIf (EBinOp "||" (EBinOp ">" (EVar "failed") (ELit (LInt 0))) (EBinOp ">" (EVar "errors") (ELit (LInt 0)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "errors")))) (ELit (LString " errors)"))) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "runTestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))
(DFunDef false "runTestReport" ((PVar "engines") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "target") (PVar "tsrc") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckGateResult") (EVar "target")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "tsrc")) (EVar "userDecls")) (arm (PCon "Some" (PVar "errText")) () (ETuple (EApp (EVar "Some") (EVar "errText")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "doctestRuns") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReport") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt"))) (DoLet false false (PVar "propResults") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReport") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "testResults") (EIf (EVar "includeTestDecls") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReport") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt")) (EListLit))) (DoExpr (ETuple (EVar "None") (EVar "doctestRuns") (EVar "propResults") (EVar "testResults") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))))))))))
(DTypeSig false "doctestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult")))))))))))))
(DFunDef false "doctestReport" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoExpr (EMatch (EVar "examples") (arm (PList) () (EApp (EVar "emptyDoctestRuns") (EVar "engines"))) (arm PWild () (EBlock (DoLet false false (PVar "synthResults") (EApp (EVar "buildSynthResults") (EVar "examples"))) (DoLet false false (PVar "synthDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")))))))))
(DTypeSig false "emptyDoctestRuns" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult")))))
(DFunDef false "emptyDoctestRuns" ((PList)) (EListLit))
(DFunDef false "emptyDoctestRuns" ((PCons (PVar "e") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (EApp (EVar "emptyDoctestRuns") (EVar "rest"))))
(DTypeSig false "doctestReportGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult")))))))))))))))
(DFunDef false "doctestReportGo" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "doctestReportGo" ((PCons (PVar "e") (PVar "rest")) (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "rest")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))))
(DTypeSig false "propsReport" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))
(DFunDef false "propsReport" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EListLit) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "propsReportSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))
(DFunDef false "propsReportSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runAllPropsResults") (EVar "cases")) (EVar "filterOpt")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EVar "env")) (EVar "rootProps")))))
(DTypeSig false "propsReportMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))
(DFunDef false "propsReportMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runAllPropsResults") (EVar "cases")) (EVar "filterOpt")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EVar "env")) (EVar "rootProps")))))))
(DTypeSig false "testDeclsReport" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReport" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EListLit) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "testDeclsReportSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReportSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EVar "runTestsCollect") (EVar "env")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests"))))))))
(DTypeSig false "testDeclsReportMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReportMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EVar "runTestsCollect") (EVar "env")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests"))))))))))
(DTypeSig false "runTestsCollect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))
(DFunDef false "runTestsCollect" (PWild (PList)) (EListLit))
(DFunDef false "runTestsCollect" ((PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EApp (EApp (EVar "runOneTest") (EVar "env")) (EVar "body"))) (EApp (EApp (EVar "runTestsCollect") (EVar "env")) (EVar "rest"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DData" false) (mem "DInterface" false) (mem "DProp" false) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseResult" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgram" false) (mem "entrySearchRoots" false) (mem "canonicalPathId" false) (mem "readDeps" false) (mem "findProjectRootOrSelf" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "readPreludeFile" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateOne" false) (mem "elaborateModules" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "mangleCtorCollisionsPair" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" false) (mem "evalOneWith" false) (mem "evalModulesWith" false) (mem "evalModulesRootEnvWith" false) (mem "testCapableExterns" false) (mem "funNamesOf" false) (mem "dropShadowedExp" false) (mem "lookupBinding" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" true) (mem "Engine" true) (mem "engineName" false) (mem "extractExamples" false) (mem "buildSynthResults" false) (mem "buildSynthDecls" false) (mem "buildDetailsFrom" false) (mem "doctestFailSuffix" false) (mem "hasUseDecls" false) (mem "printDoctestDetails" false) (mem "runDetails" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "synthName" false))))
(DUse false (UseGroup ("tools" "native_doctest") ((mem "runNativeDoctests" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "runAllProps" false) (mem "hasProps" false) (mem "runAllPropsResults" false) (mem "PropResult" false))))
(DUse false (UseGroup ("tools" "test_runner") ((mem "collectTests" false) (mem "runOneTest" false) (mem "hasTests" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeProject" false) (mem "analyzeLocated" false) (mem "readDiagSrc" false) (mem "ppDiagCliSrc" false) (mem "ppDiagCliLines" false) (mem "srcLinesArr" false) (mem "parseErrDiag" false) (mem "Diag" false) (mem "diagIsError" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "joinNl" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "endsWith" false) (mem "splitOnChar" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DTypeSig false "substringMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substringMatch" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "rootsOrDefault" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "rootsOrDefault" ((PVar "target") (PList)) (EListLit (EApp (EVar "dirOf") (EVar "target"))))
(DFunDef false "rootsOrDefault" (PWild (PVar "roots")) (EVar "roots"))
(DTypeSig true "runTest" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTest" ((PVar "engines") (PVar "runtimeP") (PVar "coreP") (PVar "target") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EMatch (EApp (EVar "readPreludeFile") (EVar "runtimeP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "coreP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EVar "parseErrDiag") (EVar "target")) (EVar "e"))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestGate") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "userDecls")) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "errText")))) (DoExpr (EVar "False")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveAll") (EVar "engines")) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")))))))))))))))
(DTypeSig false "typecheckExempt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "typecheckExempt" ((PVar "target") (PVar "userDecls") (PVar "tsrc")) (EIf (EApp (EVar "isNonEmptyL") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (EVar "False") (EIf (EApp (EVar "isNewVehiclePath") (EVar "target")) (EVar "False") (EIf (EVar "otherwise") (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EApp (EVar "hasTests") (EVar "userDecls"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isNewVehiclePath" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "isNewVehiclePath" ((PVar "target")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "target")) (EApp (EVar "hasVehicleSegment") (EApp (EVar "canonicalizePath") (EVar "target"))) (EVar "False")))
(DTypeSig false "hasVehicleSegment" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasVehicleSegment" ((PVar "path")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "filterList") (ELam ((PVar "seg")) (EBinOp "||" (EBinOp "==" (EVar "seg") (ELit (LString "compiler"))) (EBinOp "==" (EVar "seg") (ELit (LString "stdlib")))))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path")))))
(DTypeSig false "doctestGate" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "doctestGate" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "userDecls")) (EIf (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckSkipNotice") (EVar "target")) (EVar "userDecls")))) (DoExpr (EVar "None"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "userDecls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "typecheckGateResult" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "typecheckGateResult" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "userDecls")) (EIf (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc")) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "userDecls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "typecheckErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "typecheckErrors" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "userDecls")) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EVar "projectTypeErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "rsrc")) (EVar "csrc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "singleFileTypeErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "singleFileTypeErrors" ((PVar "target") (PVar "tsrc") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EApp (EApp (EApp (EVar "analyzeLocated") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs")))))))))
(DTypeSig false "projectTypeErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "projectTypeErrors" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "True")) (EListLit)) (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false (PVar "rendered") (EApp (EApp (EDictApp "flatMap") (EVar "renderFileErrors")) (EVar "triples"))) (DoExpr (EMatch (EVar "rendered") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "rendered"))))))))
(DTypeSig false "renderFileErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderFileErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "path"))) (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EVar "diags"))))
(DTypeSig false "typecheckGateFail" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typecheckGateFail" ((PVar "target") (PVar "errText")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type error in ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString " — `medaka test` requires it to `medaka check` first:\n"))) (EApp (EMethodRef "display") (EVar "errText"))) (ELit (LString ""))))
(DTypeSig false "typecheckSkipNotice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "typecheckSkipNotice" ((PVar "target") (PVar "userDecls")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "note: typechecking was skipped for ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "\n  reason: the module declares "))) (EApp (EMethodRef "display") (EApp (EVar "skipReasonDecls") (EVar "userDecls")))) (ELit (LString " and no doctests, so `medaka test` exempts it from the type checker (issue #1229) — those phases exist to exercise eval on constructs `medaka check` rejects.\n  a runtime error below may therefore be an uncaught TYPE error.\n  to type-check it: medaka check "))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ""))))
(DTypeSig false "skipReasonDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "skipReasonDecls" ((PVar "userDecls")) (EIf (EBinOp "&&" (EApp (EVar "hasTests") (EVar "userDecls")) (EApp (EVar "hasProps") (EVar "userDecls"))) (ELit (LString "`test \"…\"` and `prop \"…\"` decls")) (EIf (EApp (EVar "hasTests") (EVar "userDecls")) (ELit (LString "`test \"…\"` decls")) (EIf (EVar "otherwise") (ELit (LString "`prop \"…\"` decls")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "driveAll" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "driveAll" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProps") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDecls") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk")))))
(DTypeSig false "filterExamplesByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyApp (TyCon "List") (TyCon "Example")))))
(DFunDef false "filterExamplesByName" ((PCon "None") (PVar "examples")) (EVar "examples"))
(DFunDef false "filterExamplesByName" ((PCon "Some" (PVar "sub")) (PVar "examples")) (EApp (EApp (EVar "filterList") (ELam ((PVar "ex")) (EApp (EApp (EVar "substringMatch") (EMethodRef "sub")) (EApp (EVar "exampleInput") (EVar "ex"))))) (EVar "examples")))
(DTypeSig false "runDoctests" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "runDoctests" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running doctests in ")) (EVar "target")))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoExpr (EMatch (EVar "examples") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  (no doctests found)")))) (DoExpr (EVar "True")))) (arm PWild () (EBlock (DoLet false false (PVar "synthResults") (EApp (EVar "buildSynthResults") (EVar "examples"))) (DoLet false false (PVar "synthDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEngines") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")))))))))
(DTypeSig false "runEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool")))))))))))))
(DFunDef false "runEngines" ((PList (PVar "e")) (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EBlock (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))) (DoExpr (EApp (EApp (EVar "reportDoctests") (EVar "target")) (EVar "result")))))
(DFunDef false "runEngines" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEnginesTagged") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")))
(DTypeSig false "runEnginesTagged" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool")))))))))))))
(DFunDef false "runEnginesTagged" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EVar "True"))
(DFunDef false "runEnginesTagged" ((PCons (PVar "e") (PVar "rest")) (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "-- ")) (EApp (EMethodRef "display") (EApp (EVar "engineName") (EVar "e")))) (ELit (LString " --"))))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))) (DoLet false false (PVar "ok") (EApp (EApp (EVar "reportDoctests") (EVar "target")) (EVar "result"))) (DoLet false false (PVar "restOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEnginesTagged") (EVar "rest")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))) (DoExpr (EBinOp "&&" (EVar "ok") (EVar "restOk")))))
(DTypeSig true "runChosenOn" (TyFun (TyCon "Engine") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))))
(DFunDef false "runChosenOn" ((PCon "EngInterp") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "_tsrc") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosen") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")))
(DFunDef false "runChosenOn" ((PCon "EngNative") (PVar "_runtimeDecls") (PVar "_coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "_roots") (PVar "examples") (PVar "_synthDecls") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EVar "runNativeDoctests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))
(DTypeSig false "runChosen" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))
(DFunDef false "runChosen" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "renderExamples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderExamples" ((PVar "env") (PVar "examples")) (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (ELit (LInt 0))) (EVar "examples")))
(DTypeSig false "renderExamplesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "renderExamplesGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "renderExamplesGo" ((PVar "env") (PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "renderOneExample") (EVar "env")) (EVar "i")) (EVar "ex")) (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "renderOneExample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderOneExample" ((PVar "env") (PVar "i") (PVar "ex")) (EMatch (EApp (EApp (EVar "lookupBinding") (EApp (EVar "synthName") (EVar "i"))) (EVar "env")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "could not evaluate: ")) (EApp (EVar "exampleInput") (EVar "ex"))))) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))))))
(DTypeSig true "singleRootId" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "singleRootId" ((PVar "roots") (PVar "target")) (EBlock (DoLet false false (PVar "deps") (EApp (EVar "readDeps") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "target"))))) (DoExpr (EApp (EApp (EApp (EVar "canonicalPathId") (EVar "deps")) (EVar "roots")) (EVar "target")))))
(DTypeSig false "runSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))
(DFunDef false "runSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EBlock (DoLet false false (PVar "allUser") (EBinOp "++" (EVar "userDecls") (EVar "synthDecls"))) (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "allUser"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateOne") (EVar "runtimeDecls")) (EVar "livePrelude")) (ETuple (EVar "rootId") (EVar "allUser")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalOneWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EListLit)) (ETuple (ELit (LString "__main__")) (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))
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
(DTypeSig false "runMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))
(DFunDef false "runMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "_userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Err") (EVar "e"))) (EVar "synthResults")) (EVar "examples"))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "injected") (EApp (EApp (EApp (EVar "injectIntoRoot") (EVar "target")) (EVar "synthDecls")) (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "injected"))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "p"))))
(DTypeSig false "injectIntoRoot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "injectIntoRoot" (PWild (PVar "synthDecls") (PVar "mods")) (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EVar "mods")))
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
(DFunDef false "collectPropLines" ((PCons (PCon "DProp" PWild (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "exprLineLocal") (EVar "body"))) (EApp (EVar "collectPropLines") (EVar "rest"))))
(DFunDef false "collectPropLines" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectPropLines") (EVar "rest")))
(DTypeSig false "exprLineLocal" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprLineLocal" ((PCon "ELoc" (PCon "Loc" PWild (PVar "l") PWild PWild PWild) PWild)) (EVar "l"))
(DFunDef false "exprLineLocal" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "exprLineLocal") (EVar "f")))
(DFunDef false "exprLineLocal" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "exprLineLocal") (EVar "e")))
(DFunDef false "exprLineLocal" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "exprLineLocal") (EVar "e")))
(DFunDef false "exprLineLocal" (PWild) (ELit (LInt 0)))
(DTypeSig false "elaborateModulesMangled" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "elaborateModulesMangled" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild) () (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE"))))))
(DTypeSig false "runProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "runProps" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EVar "True") (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropsMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropsSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "runPropsSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "runPropsSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runAllProps") (EVar "cases")) (EVar "filterOpt")) (EVar "target")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EVar "env")) (EVar "rootProps")))))
(DTypeSig false "runPropsMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "runPropsMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runAllProps") (EVar "cases")) (EVar "filterOpt")) (EVar "target")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EVar "env")) (EVar "rootProps")))))))
(DTypeSig false "elaboratedRootProps" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "elaboratedRootProps" (PWild (PVar "modules") (PVar "userDecls")) (EMatch (EApp (EVar "lastModule") (EVar "modules")) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls"))))
(DTypeSig false "lastModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "lastModule" ((PList)) (EVar "None"))
(DFunDef false "lastModule" ((PList (PTuple PWild (PVar "decls")))) (EApp (EVar "Some") (EVar "decls")))
(DFunDef false "lastModule" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModule") (EVar "rest")))
(DTypeSig false "lookupModuleDecls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lookupModuleDecls" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupModuleDecls" ((PVar "rootId") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "mid") (EVar "rootId")) (EApp (EVar "Some") (EVar "decls")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runTestDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestDecls" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EVar "True") (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "testLineTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "testLineTests" ((PVar "tsrc")) (EApp (EVar "collectTests") (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "tsrc")))))
(DTypeSig false "filterTestsByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))
(DFunDef false "filterTestsByName" ((PCon "None") (PVar "tests")) (EVar "tests"))
(DFunDef false "filterTestsByName" ((PCon "Some" (PVar "sub")) (PVar "tests")) (EApp (EApp (EVar "filterList") (ELam ((PVar "t")) (EApp (EApp (EVar "substringMatch") (EMethodRef "sub")) (EApp (EVar "fst3") (EVar "t"))))) (EVar "tests")))
(DTypeSig false "fst3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "a")))
(DFunDef false "fst3" ((PTuple (PVar "a") PWild PWild)) (EVar "a"))
(DTypeSig false "runTestDeclsSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestDeclsSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EApp (EVar "reportTests") (EVar "target")) (EVar "env")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests"))))))))
(DTypeSig false "runTestDeclsMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestDeclsMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EApp (EVar "reportTests") (EVar "target")) (EVar "env")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests"))))))))))
(DTypeSig false "attachRawLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))
(DFunDef false "attachRawLines" (PWild (PList)) (EListLit))
(DFunDef false "attachRawLines" ((PList) (PCons (PTuple (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (ELit (LInt 0)) (EVar "body")) (EApp (EApp (EVar "attachRawLines") (EListLit)) (EVar "rest"))))
(DFunDef false "attachRawLines" ((PCons (PTuple PWild (PVar "l") PWild) (PVar "rawRest")) (PCons (PTuple (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "l") (EVar "body")) (EApp (EApp (EVar "attachRawLines") (EVar "rawRest")) (EVar "rest"))))
(DTypeSig false "reportTests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "reportTests" ((PVar "target") (PVar "env") (PVar "tests")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running tests in ")) (EVar "target")))) (DoLet false false (PTuple (PVar "passed") (PVar "failed") (PVar "errors")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EVar "passed") (EVar "failed")) (EVar "errors"))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " passed"))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EVar "testFailSuffix") (EVar "failed")) (EVar "errors")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EVar "failed") (ELit (LInt 0))) (EBinOp "==" (EVar "errors") (ELit (LInt 0)))))))
(DTypeSig false "runTestLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))))))))
(DFunDef false "runTestLoop" (PWild PWild (PList) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EVar "errors")))
(DFunDef false "runTestLoop" ((PVar "target") (PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest")) (PVar "passed") (PVar "failed") (PVar "errors")) (EBlock (DoLet false false (PVar "loc") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  running ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EMatch (EApp (EApp (EVar "runOneTest") (EVar "env")) (EVar "body")) (arm (PCon "Pass") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ok   ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EBinOp "+" (EVar "passed") (ELit (LInt 1)))) (EVar "failed")) (EVar "errors"))))) (arm (PCon "Fail" (PVar "msg") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EVar "passed")) (EBinOp "+" (EVar "failed") (ELit (LInt 1)))) (EVar "errors"))))) (arm (PCon "Errored" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EVar "passed")) (EVar "failed")) (EBinOp "+" (EVar "errors") (ELit (LInt 1)))))))))))
(DTypeSig false "testFailSuffix" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "testFailSuffix" ((PVar "failed") (PVar "errors")) (EIf (EBinOp "||" (EBinOp ">" (EVar "failed") (ELit (LInt 0))) (EBinOp ">" (EVar "errors") (ELit (LInt 0)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "errors")))) (ELit (LString " errors)"))) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "runTestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))
(DFunDef false "runTestReport" ((PVar "engines") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "target") (PVar "tsrc") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckGateResult") (EVar "target")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "tsrc")) (EVar "userDecls")) (arm (PCon "Some" (PVar "errText")) () (ETuple (EApp (EVar "Some") (EVar "errText")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "doctestRuns") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReport") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt"))) (DoLet false false (PVar "propResults") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReport") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "testResults") (EIf (EVar "includeTestDecls") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReport") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt")) (EListLit))) (DoExpr (ETuple (EVar "None") (EVar "doctestRuns") (EVar "propResults") (EVar "testResults") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))))))))))
(DTypeSig false "doctestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult")))))))))))))
(DFunDef false "doctestReport" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoExpr (EMatch (EVar "examples") (arm (PList) () (EApp (EVar "emptyDoctestRuns") (EVar "engines"))) (arm PWild () (EBlock (DoLet false false (PVar "synthResults") (EApp (EVar "buildSynthResults") (EVar "examples"))) (DoLet false false (PVar "synthDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")))))))))
(DTypeSig false "emptyDoctestRuns" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult")))))
(DFunDef false "emptyDoctestRuns" ((PList)) (EListLit))
(DFunDef false "emptyDoctestRuns" ((PCons (PVar "e") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (EApp (EVar "emptyDoctestRuns") (EVar "rest"))))
(DTypeSig false "doctestReportGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult")))))))))))))))
(DFunDef false "doctestReportGo" ((PList) PWild PWild PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "doctestReportGo" ((PCons (PVar "e") (PVar "rest")) (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "rest")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))))
(DTypeSig false "propsReport" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))
(DFunDef false "propsReport" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EListLit) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReportSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "propsReportSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))
(DFunDef false "propsReportSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runAllPropsResults") (EVar "cases")) (EVar "filterOpt")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EVar "env")) (EVar "rootProps")))))
(DTypeSig false "propsReportMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))))
(DFunDef false "propsReportMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runAllPropsResults") (EVar "cases")) (EVar "filterOpt")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EVar "env")) (EVar "rootProps")))))))
(DTypeSig false "testDeclsReport" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReport" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EListLit) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "testDeclsReportSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReportSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EVar "runTestsCollect") (EVar "env")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests"))))))))
(DTypeSig false "testDeclsReportMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReportMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots") (PVar "filterOpt")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EVar "runTestsCollect") (EVar "env")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests"))))))))))
(DTypeSig false "runTestsCollect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))
(DFunDef false "runTestsCollect" (PWild (PList)) (EListLit))
(DFunDef false "runTestsCollect" ((PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EApp (EApp (EVar "runOneTest") (EVar "env")) (EVar "body"))) (EApp (EApp (EVar "runTestsCollect") (EVar "env")) (EVar "rest"))))
