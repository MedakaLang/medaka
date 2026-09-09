# META
source_lines=2289
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
-- the two files being siblings in one directory.  `test/origin_fixtures/nested`
-- is the CROSS-DIRECTORY witness: `main_nested.mdk` sits at the fixture root
-- and `src/leaf.mdk` is nested a directory below it, and the two AGREE.
-- Previously this was the synthetic literal `"__user__"`, hardcoded at every
-- single-file call site below.

import frontend.ast.{Decl, DData, DInterface, DProp, Expr(..), Loc(..)}
import frontend.parser.{parse, parseLocated, parseResult}
import frontend.desugar.{desugar}
import frontend.desugar_cache.{desugaredPrelude, desugaredPreludeKey}
import driver.loader.{
  loadProgramFilesLocatedE,
  loadErrorMessage,
  LoadError(..),
  entrySearchRoots,
  canonicalPathId,
  readDeps,
  findProjectRoot,
  findProjectRootOrSelf,
}
import driver.build_cmd.{readPreludeFile, envOr, defaultMedakaRoot}
import types.typecheck.{elaborateOne, elaborateModules, TcDiag}
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
  exResultJsonFields,
}
import tools.native_doctest.{runNativeDoctests}
import tools.native_test_decls.{runNativeTests}
import tools.prop_runner.{
  runAllProps,
  hasProps,
  runAllPropsResults,
  PropResult,
  filterProps,
  filterPropsByName,
  propResultName,
  propResultPassed,
  propResultDetail,
}
import tools.test_runner.{collectTests, runOneTest, hasTests, uncapableExterns}
import driver.diagnostics.{
  analyzeLocated,
  projectDiagsFromTc,
  projectDiagsLoaded,
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
}
import support.path.{dirOf, baseOf, joinPath}
import args.{
  ArgSpec, Args, spec, switch, value, flag, flagValue, withStrictDash
}
import json.{Json, JInt, JString, JBool, jObject, jArray}
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
            let exempt = typecheckExempt target userDecls tsrc
            let _ = exemptNotice exempt target userDecls
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
      || underProjectTestDir target
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
  let errs = filter diagIsError (analyzeLocated rsrc csrc tsrc)
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
  renderGate (projectDiagsFromTc True [] runtimeDecls coreDecls mods perModule)

-- A load failure reaches the gate as the diagnostic `analyzeProject` attributes
-- to it: a parse failure to the module that owns it, anything else (unknown
-- module, cycle, unreadable file) to the entry.
loadGate : Bool -> String -> LoadError -> <IO> Option String
loadGate True _ _ = None
loadGate False target le = renderGate (loadErrorDiags target le)

loadErrorDiags : String -> LoadError -> List (String, List Diag)
loadErrorDiags _ (LoadParseFailed mpath _ pe) =
  [(mpath, [parseErrDiag mpath pe])]
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
-- props, `test "…"`) used to report `0/0 passed` and exit 0 — a filter typo
-- looked identical to a genuinely clean run. A module that declares zero
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
--   TestPair core mods  the elaborated, ctor-mangled pair every phase evaluates
--   TestPairErr msg     a loader failure standing in for it, so each phase
--                       reports it exactly as it always has
data TestPair =
  | TestPair (List Decl) (List (String, List Decl))
  | TestPairErr String

-- What the DOCTEST phase's interpreter arm evaluates.  The two shapes are NOT
-- interchangeable, which is why this is a separate type rather than a third
-- `TestPair` constructor: the single-file arm hands `evalOneWith` an EMPTY
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
-- `runAsyncIO (…)` examples perform `<Clock>`, so the synthesized
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
-- between them.  `elabWorker` and `cmModuleWorker` both pass `accAll ++ prog`
-- (types/typecheck.mdk); if that ever diverges again, this split is unsound and
-- both arms must move to one driver.  `hasDoctests` is the module's UNFILTERED
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
  match elaborateModules runtimeDecls coreDecls (desugaredModPairs mods)
    (coreE, modulesE, perModule, _, _) => (
      gateOfPerModule exempt runtimeDecls coreDecls mods perModule,
      PreparedPair (uncurryPair (mangleCtorCollisionsPair (coreE, modulesE))),
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
    (coreE, modulesE, _, _, _) =>
      uncurryPair (mangleCtorCollisionsPair (coreE, modulesE))

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
      True
      []
      (desugaredPrelude rsrc)
      (desugaredPrelude csrc)
      (Some (desugaredPreludeKey rsrc, desugaredPreludeKey csrc))
      (chainKeyOf target roots)
      mods)

uncurryPair : (List Decl, List (String, List Decl)) -> TestPair
uncurryPair (core, mods) = TestPair core mods

-- The single-file prop/`test "…"` arm's elaboration: the degenerate 1-module
-- list over the shadow-dropped prelude (`programIsCore` ⇒ [], so `medaka test
-- stdlib/core.mdk` does not double-prepend it).  Built once and shared by the
-- two phases, which used to elaborate it once each.
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
  uncurryPair
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
  <IO> Bool
driveAll engines runtimeDecls coreDecls rsrc csrc target tsrc roots cases filterOpt userDecls exempt
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
  <IO> Bool
driveMulti engines runtimeDecls rsrc csrc target tsrc roots cases filterOpt userDecls exempt =
  let allExamples = extractExamples (collectComments tsrc)
  let examples = filterExamplesByName filterOpt allExamples
  let synthResults = buildSynthResults examples
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
        let propsOk = runProps pair target tsrc userDecls cases filterOpt
        let testsOk =
          runTestDecls engines pair runtimeDecls target tsrc userDecls filterOpt
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
  <IO> Bool
driveSingle engines runtimeDecls coreDecls target tsrc roots cases filterOpt userDecls =
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
        (buildSynthResults examples)
    if hasProps userDecls || hasTests userDecls then
      let pair = prepareSingle runtimeDecls coreDecls target roots userDecls
      let propsOk = runProps pair target tsrc userDecls cases filterOpt
      let testsOk =
        runTestDecls engines pair runtimeDecls target tsrc userDecls filterOpt
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
-- across engines. With exactly one engine — `[EngInterp]`, the default — the
-- report is BYTE-IDENTICAL to `medaka test`'s pre-#81-Stage-3 output: no
-- engine tag is printed, and only ONE build/run happens. `--native` adds
-- `EngNative` to the list, and each engine's block is labelled so the two
-- reports (and their independent pass/fail) don't run together.
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
  let exempt = typecheckExempt target userDecls tsrc
  runNativeDoctests target tsrc userDecls examples synthResults (not exempt)

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
-- FLAT shape `evalOneWith` consumes, and its rootLocals carry the synthesized
-- `__dt_i__` bindings the same way the pair arm's do.
runChosen : DoctestTrees ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> RunResult
runChosen (DtPair (TestPairErr e)) examples synthResults =
  buildDetailsFrom (Err e) synthResults examples
runChosen (DtPair (TestPair coreM modsM)) examples synthResults =
  let env = evalModulesWith (testCapableExterns ()) coreM modsM
  buildDetailsFrom (Ok (renderExamples env examples)) synthResults examples
runChosen (DtSingle runtimeDecls coreDecls target roots userDecls) examples synthResults =
  let allUser = userDecls ++ buildSynthDecls synthResults
  let livePrelude =
    if programIsCore userDecls then
      []
    else
      dropShadowedExp (funNamesOf allUser) coreDecls
  let rootId = singleRootId roots target
  let elaborated = elaborateOne runtimeDecls livePrelude (rootId, allUser)
  let env = evalOneWith (testCapableExterns ()) [] ("__main__", elaborated)
  buildDetailsFrom (Ok (renderExamples env examples)) synthResults examples

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
-- shared by the prelude-only doctest arm and `prepareSingle`.  `deps` mirrors
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

-- DRIVER-COLLAPSE Phase 1+3 note on the dict-set: the old `coreDictNames`
-- externally-built dict-set (preludeReturnPosDictNames ++ constrainedSigNames, with
-- arg-position helpers excluded to keep the `neq`-hang closed) is gone — the
-- single-file arms route through elaborateModules, which OWNS the
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
    (coreE, modulesE, _, _, _) => mangleCtorCollisionsPair (coreE, modulesE)

-- Evaluate the file's `prop "…"` decls in the shared elaboration's root
-- environment.  `evalModulesRootEnv` exposes the prelude globals (eq/compare)
-- the prop bodies need, and the bodies themselves come from the ELABORATED root
-- module (dict-passed call sites) so the file's own `=>`-constrained fns (set's
-- `fromList`/`wellFormed`) get their leading dict argument — raw bodies would
-- under-apply the now-dict-passed call and `force` a partial closure, so every
-- prop would "fail".
runProps : TestPair ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  <IO> Bool
runProps pair target tsrc userDecls cases filterOpt
  | not (hasProps userDecls) = True
  | otherwise = match pair
    TestPairErr e =>
      let _ = ePutStrLn e
      False
    TestPair coreM modsM =>
      let env = evalModulesRootEnvWith (testCapableExterns ()) coreM modsM
      runAllProps
        cases
        filterOpt
        target
        (propLineTests tsrc)
        env
        (elaboratedRootProps modsM userDecls)

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

-- #2588: `engines` selects the execution engine(s) the same way the doctest
-- phase's does — `[EngInterp]` (the default) is byte-identical to the pre-#2588
-- report, `--native` adds `EngNative`, and each engine's block is labelled when
-- there is more than one.  Until #2588 this phase took no `Engine` at all, so
-- `--native` and `--engines` were silently inert for `test "…"` decls even
-- though they already worked for doctests.
runTestDecls : List Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  <IO> Bool
runTestDecls engines pair runtimeDecls target tsrc userDecls filterOpt
  | not (hasTests userDecls) = True
  | otherwise =
    runTestEngines engines pair runtimeDecls target tsrc userDecls filterOpt

runTestEngines : List Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  <IO> Bool
runTestEngines [e] pair runtimeDecls target tsrc userDecls filterOpt =
  runTestsOn e pair runtimeDecls target tsrc userDecls filterOpt
runTestEngines engines pair runtimeDecls target tsrc userDecls filterOpt =
  runTestEnginesTagged engines pair runtimeDecls target tsrc userDecls filterOpt

runTestEnginesTagged : List Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  <IO> Bool
runTestEnginesTagged [] _ _ _ _ _ _ = True
runTestEnginesTagged (e :: rest) pair runtimeDecls target tsrc userDecls filterOpt =
  let _ = putStrLn ""
  let _ = putStrLn "-- \{engineName e} --"
  let ok = runTestsOn e pair runtimeDecls target tsrc userDecls filterOpt
  let restOk =
    runTestEnginesTagged rest pair runtimeDecls target tsrc userDecls filterOpt
  ok && restOk

-- The SINGLE call site that picks an execution engine for the `test "…"`
-- phase.  `EngInterp` evaluates each elaborated body through the interpreter;
-- `EngNative` compiles ONE probe binary per file (tools.native_test_decls) and
-- reads the `Expectation`s it prints.  The two arms genuinely differ in how
-- they reach a body — an elaborated `Expr` versus a re-rendered binding — which
-- is why that module is `native_doctest.mdk`'s template rather than its caller.
runTestsOn : Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  <IO> Bool
runTestsOn EngInterp (TestPairErr e) _runtimeDecls _target _tsrc _userDecls _filterOpt =
  let _ = ePutStrLn e
  False
runTestsOn EngInterp (TestPair coreM modsM) runtimeDecls target tsrc userDecls filterOpt =
  gatedReportTests
    target
    (runtimeDecls ++ coreM ++ flatMap snd modsM)
    (evalModulesRootEnvWith (testCapableExterns ()) coreM modsM)
    (rootTestsOf filterOpt tsrc modsM userDecls)
runTestsOn EngNative _pair _runtimeDecls target tsrc userDecls filterOpt =
  runTestDeclsNative target tsrc userDecls filterOpt

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
runTestDeclsNative : String -> String -> List Decl -> Option String -> <IO> Bool
runTestDeclsNative target tsrc userDecls filterOpt =
  let tests = filterTestsByName filterOpt (nativeRawTests tsrc)
  let _ = putStrLn ("running tests in " ++ target)
  let exempt = typecheckExempt target userDecls tsrc
  reportNativeTests
    target
    tests
    (runNativeTests target tsrc userDecls tests (not exempt))

nativeRawTests : String -> List (String, Int, Expr)
nativeRawTests tsrc = collectTests (parseLocated tsrc)

reportNativeTests : String ->
  List (String, Int, Expr) ->
  List ExResult ->
  <IO> Bool
reportNativeTests target tests results =
  let (passed, failed, errors) = nativeTestLoop target tests results 0 0 0
  reportTestSummary target passed failed errors

nativeTestLoop : String ->
  List (String, Int, Expr) ->
  List ExResult ->
  Int ->
  Int ->
  Int ->
  <IO> (Int, Int, Int)
nativeTestLoop _ [] _ passed failed errors = (passed, failed, errors)
nativeTestLoop _ (_ :: _) [] passed failed errors = (passed, failed, errors)
nativeTestLoop target ((name, line, _) :: rest) (r :: rRest) passed failed errors =
  let _ = printTestRunning target line name
  let _ = printTestVerdict target line name r
  let (p, f, e) = tallyTest r passed failed errors
  nativeTestLoop target rest rRest p f e

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

-- ── the eval arm's capability gate (#2588) ──────────────────────────────────
-- `medaka test` evaluates `test "…"` bodies under a capability policy
-- (eval.testCapableExterns) that binds the clock, the GC counter and stderr and
-- nothing else.  A body reaching past it — directly, or through a stdlib
-- wrapper like `runCommandOk` — used to die mid-run with eval's own `unbound
-- identifier runCommand`, a message about the interpreter's internals that
-- named no test and arrived after earlier tests had already reported.
--
-- The gate answers the same question by name, before anything runs, and refuses
-- the WHOLE FILE rather than the individual test: the tests that would still
-- have run are not the point when the file as written cannot be run as asked.
-- `--native` compiles a real binary and so has no such policy, which is what
-- the diagnostic points at.
gatedReportTests : String ->
  List Decl ->
  List (String, Value e) ->
  List (String, Int, Expr) ->
  <IO> Bool
gatedReportTests target corpus env tests =
  match uncapableExterns corpus env tests
    [] => reportTests target env tests
    names =>
      let _ = ePutStrLn (uncapableExternsMsg target names)
      False

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
reportTests : String ->
  List (String, Value e) ->
  List (String, Int, Expr) ->
  <IO> Bool
reportTests target env tests =
  let _ = putStrLn ("running tests in " ++ target)
  let (passed, failed, errors) = runTestLoop target env tests 0 0 0
  reportTestSummary target passed failed errors

-- The per-file summary line + exit signal, shared by both engines so their
-- reports can be compared line for line.
reportTestSummary : String -> Int -> Int -> Int -> <IO> Bool
reportTestSummary target passed failed errors =
  let total = passed + failed + errors
  let _ =
    putStr "\n\{target}: \{intToString passed}/\{intToString total} passed"
  let _ = putStr (testFailSuffix failed errors)
  let _ = putStr "\n"
  failed == 0 && errors == 0

-- #2293: name the test BEFORE its outcome is known. Panics are uncatchable by
-- design (settled: isolation only, never catchability), so under the
-- interpreter this print is the runner's only chance to attribute a mid-run
-- process death — if the process dies inside `runOneTest`, this line is the
-- last thing on stdout, and the disappearance of every test after it is
-- explained rather than mysterious.
printTestRunning : String -> Int -> String -> <IO> Unit
printTestRunning target line name =
  putStrLn "  running \{target}:\{intToString line}: \{name}"

printTestVerdict : String -> Int -> String -> ExResult -> <IO> Unit
printTestVerdict target line name result =
  let loc = "\{target}:\{intToString line}"
  match result
    Pass _ _ => putStrLn "  ok   \{loc}: \{name}"
    Fail msg _ _ =>
      let _ = putStrLn "  FAIL \{loc}: \{name}"
      putStrLn ("       " ++ msg)
    Errored msg =>
      let _ = putStrLn "  FAIL \{loc}: \{name}"
      putStrLn ("       " ++ msg)

tallyTest : ExResult -> Int -> Int -> Int -> (Int, Int, Int)
tallyTest (Pass _ _) passed failed errors = (passed + 1, failed, errors)
tallyTest (Fail _ _ _) passed failed errors = (passed, failed + 1, errors)
tallyTest (Errored _) passed failed errors = (passed, failed, errors + 1)

runTestLoop : String ->
  List (String, Value e) ->
  List (String, Int, Expr) ->
  Int ->
  Int ->
  Int ->
  <IO> (Int, Int, Int)
runTestLoop _ _ [] passed failed errors = (passed, failed, errors)
runTestLoop target env ((name, line, body) :: rest) passed failed errors =
  let _ = printTestRunning target line name
  let result = runOneTest env body
  let _ = printTestVerdict target line name result
  let (p, f, e) = tallyTest result passed failed errors
  runTestLoop target env rest p f e

testFailSuffix : Int -> Int -> String
testFailSuffix failed errors
  | failed > 0 || errors > 0 =
    " (\{intToString failed} failed, \{intToString errors} errors)"
  | otherwise = ""

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
  <IO> (Option String, List (Engine, RunResult), List PropResult, List (Engine, String, Int, ExResult), Bool)
runTestReport engines runtimeSrc coreSrc target tsrc stdlibDir cases filterOpt includeTestDecls =
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
  <IO> (Option String, List (Engine, RunResult), List PropResult, List (Engine, String, Int, ExResult), Bool)
reportMulti engines runtimeDecls rsrc csrc target tsrc roots cases filterOpt includeTestDecls userDecls exempt =
  let allExamples = extractExamples (collectComments tsrc)
  let examples = filterExamplesByName filterOpt allExamples
  let synthResults = buildSynthResults examples
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
        propsReport pair target tsrc userDecls cases filterOpt,
        reportTestDecls
          includeTestDecls
          engines
          pair
          runtimeDecls
          target
          tsrc
          userDecls
          filterOpt,
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
  <IO> (Option String, List (Engine, RunResult), List PropResult, List (Engine, String, Int, ExResult), Bool)
reportSingle engines runtimeDecls coreDecls target tsrc roots cases filterOpt includeTestDecls userDecls exempt =
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
      (buildSynthResults examples)
  if hasProps userDecls || includeTestDecls && hasTests userDecls then
    let pair = prepareSingle runtimeDecls coreDecls target roots userDecls
    (
      None,
      doctestRuns,
      propsReport pair target tsrc userDecls cases filterOpt,
      reportTestDecls
        includeTestDecls
        engines
        pair
        runtimeDecls
        target
        tsrc
        userDecls
        filterOpt,
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
  <IO> List (Engine, String, Int, ExResult)
reportTestDecls False _ _ _ _ _ _ _ = []
reportTestDecls True engines pair runtimeDecls target tsrc userDecls filterOpt =
  testDeclsReport engines pair runtimeDecls target tsrc userDecls filterOpt

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

-- Prop phase as pure data: same single-file/multi-module split as runProps, but
-- calling runAllPropsResults (silent) instead of runAllProps (printing).
-- `cases`/`filterOpt` mirror `runProps`' own parameters (F1: `medaka test
-- --json --cases`/`--filter` were silently ignored) — MCP's medaka_test still
-- passes `(100, None)` (unchanged behavior, #2295 is scoped to the CLI).
propsReport : TestPair ->
  String ->
  String ->
  List Decl ->
  Int ->
  Option String ->
  <IO> List PropResult
propsReport pair target tsrc userDecls cases filterOpt
  | not (hasProps userDecls) = []
  | otherwise = match pair
    TestPairErr _ => []
    TestPair coreM modsM =>
      runAllPropsResults
        cases
        filterOpt
        (propLineTests tsrc)
        (evalModulesRootEnvWith (testCapableExterns ()) coreM modsM)
        (elaboratedRootProps modsM userDecls)

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
testDeclsReport : List Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  <IO> List (Engine, String, Int, ExResult)
testDeclsReport engines pair runtimeDecls target tsrc userDecls filterOpt
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

testDeclsReportEngines : List Engine ->
  TestPair ->
  List Decl ->
  String ->
  String ->
  List Decl ->
  Option String ->
  <IO> List (Engine, String, Int, ExResult)
testDeclsReportEngines [] _ _ _ _ _ _ = []
testDeclsReportEngines (e :: rest) pair runtimeDecls target tsrc userDecls filterOpt =
  map
      (t => tagWithEngine e t)
      (testDeclsReportOn e pair runtimeDecls target tsrc userDecls filterOpt)
    ++ testDeclsReportEngines
      rest
      pair
      runtimeDecls
      target
      tsrc
      userDecls
      filterOpt

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
  <IO> List (String, Int, ExResult)
testDeclsReportOn EngInterp (TestPairErr _) _runtimeDecls _target _tsrc _userDecls _filterOpt =
  []
testDeclsReportOn EngInterp (TestPair coreM modsM) runtimeDecls target tsrc userDecls filterOpt =
  gatedTestsCollect
    target
    (runtimeDecls ++ coreM ++ flatMap snd modsM)
    (evalModulesRootEnvWith (testCapableExterns ()) coreM modsM)
    (rootTestsOf filterOpt tsrc modsM userDecls)
testDeclsReportOn EngNative _pair _runtimeDecls target tsrc userDecls filterOpt =
  let tests = filterTestsByName filterOpt (nativeRawTests tsrc)
  let exempt = typecheckExempt target userDecls tsrc
  zipTestResults tests (runNativeTests target tsrc userDecls tests (not exempt))

zipTestResults : List (String, Int, Expr) ->
  List ExResult ->
  List (String, Int, ExResult)
zipTestResults [] _ = []
zipTestResults (_ :: _) [] = []
zipTestResults ((name, line, _) :: rest) (r :: rRest) =
  (name, line, r) :: zipTestResults rest rRest

-- The `--json` twin of `gatedReportTests`: the capability refusal reaches this
-- surface as one `Errored` per test carrying the same message, so a machine
-- reader sees `"status":"error"` with the offending extern named rather than a
-- silently empty `tests` array.
gatedTestsCollect : String ->
  List Decl ->
  List (String, Value e) ->
  List (String, Int, Expr) ->
  <IO> List (String, Int, ExResult)
gatedTestsCollect target corpus env tests =
  match uncapableExterns corpus env tests
    [] => runTestsCollect env tests
    names =>
      let msg = uncapableExternsMsg target names
      map (t => (fst3 t, snd3 t, Errored msg)) tests

snd3 : (a, b, c) -> b
snd3 (_, b, _) = b

runTestsCollect : List (String, Value e) ->
  List (String, Int, Expr) ->
  <IO> List (String, Int, ExResult)
runTestsCollect _ [] = []
runTestsCollect env ((name, line, body) :: rest) =
  (name, line, runOneTest env body) :: runTestsCollect env rest

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
  "  --native            run doctests through a compiled native binary\n",
  "                      instead of the interpreter (shorthand for\n",
  "                      --engines native)\n",
  "  --engines e1,e2,...  run the listed engine set (known: eval, native);\n",
  "                      exit code is the AND across engines\n",
  "  --json               emit a {\"file\":...,\"doctests\":...,\"properties\":...,\n",
  "                      \"tests\":...,\"summary\":...} JSON object instead of\n",
  "                      human text (single file.mdk target only; agrees with\n",
  "                      the human report's pass/fail counts on all three\n",
  "                      phases)\n",
  "  --filter <substring> restrict to doctests/`test \"…\"`/`prop \"…\"` whose\n",
  "                      name (or, for a doctest, input expression) contains\n",
  "                      <substring>\n",
  "  --seed <n>           seed the property-test RNG (printed on every prop\n",
  "                      failure so the counterexample is replayable); never\n",
  "                      affects a program under test's own random draws\n",
  "  --cases <n>           run each property with <n> generated cases\n",
  "                      instead of the default 100\n", "\n",
  "--native and --engines are mutually exclusive. With neither, the default\n",
  "is the interpreter (eval) alone. A file.mdk or dir target is required.\n"
]

-- #2316: any `--`-prefixed token must be one of the known `medaka test`
-- flags. The pre-#2316 `testTargets` fallthrough (`startsWith "--" x =
-- testTargets rest`) dropped ANY unrecognized `--`-shaped token
-- unconditionally — so `--engines=native` (the `=`-form, which nothing then
-- parsed as `--engines`) silently vanished, `parseTestEngines` saw no
-- `--engines`/`--native` at all, and the run defaulted to the interpreter and
-- exited 0 with no diagnostic.  The spec below is what rejects it now.
-- Declaration order is the roster order, reproducing the old
-- `testBoolFlags ++ testValueFlags` rendering.
--
-- `--seed`/`--cases` are `value`, not `intValue`, and `--engines` is `value`,
-- not `oneOf`: their rejection sentences are `parseTestIntFlag`'s and
-- `parseEngineNames`'s own hand-written ones, and this slice keeps every one
-- of them verbatim (convergence onto `args.mdk`'s `invalidValueMessage` is a
-- later decision, not this slice's).
-- `withStrictDash` (S-5, #2355 residual A): an undeclared `-x` used to fall
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
-- `[EngInterp]`.
export
parseTestEngines : Args -> Result String (List Engine)
parseTestEngines a = match (flagValue "--engines" a, flag "--native" a)
  (Some _, True) =>
    Err
      "--native and --engines are mutually exclusive; --native is shorthand for --engines native"
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
-- Structurally identical to mcp.mdk's `propJson` — both render the same
-- `PropResult` shape for their own JSON envelope, and neither module imports
-- the other (mcp.mdk is a CLI-independent server surface); not worth a shared
-- module for one 5-line function.
-- lint-disable-next-line rule-duplicate-body
cliPropJson p = jObject [
  ("name", JString (propResultName p)),
  ("status", JString (if propResultPassed p then "pass" else "fail")),
  ("detail", JString (propResultDetail p)),
]

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

-- The full envelope: doctests + properties (same shape `medaka_test`'s
-- `testReportJson` uses) PLUS a `tests` array for `test "…"` decls, and a
-- `summary` folding all three phases together — this is the field
-- `testReportJson` cannot provide (it never runs this phase, by its own
-- documented scope), and the one this slice's acceptance check depends on.
export
cliTestReportJson : String ->
  Option String ->
  List (Engine, RunResult) ->
  List PropResult ->
  List (Engine, String, Int, ExResult) ->
  Bool ->
  Json
cliTestReportJson path typeError runs props tests typecheckSkipped =
  jObject
    ([("file", JString path)]
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
-- count/filter — the same three knobs `runTestCmd` read from its OWN argv,
-- round-tripped rather than re-parsed by the child.
testChildArgs : List Engine -> Int -> Option String -> String -> List String
testChildArgs engines cases filterOpt f =
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

-- Fold over an expanded file list, aggregating whether ANY file failed
-- (tests failed, the file itself couldn't be read/parsed, or the child
-- process died). Each file runs `runTest` in its OWN child process — a
-- panic in file 3 of 20 used to abort the whole in-process loop, so files
-- 4-20 never printed anything (#2589 item 1). Spawning per file means a
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
  List String ->
  Bool ->
  <IO> Bool
testFilesGo _ _ _ _ _ _ [] acc = acc
testFilesGo engines rtPath corePath stdlibDir cases filterOpt (f :: rest) acc =
  let medaka = envOr "MEDAKA" (executablePath ())
  let args = testChildArgs engines cases filterOpt f
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
    rest
    (acc || not ok)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DData" false) (mem "DInterface" false) (mem "DProp" false) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseResult" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "desugaredPreludeKey" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgramFilesLocatedE" false) (mem "loadErrorMessage" false) (mem "LoadError" true) (mem "entrySearchRoots" false) (mem "canonicalPathId" false) (mem "readDeps" false) (mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "readPreludeFile" false) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateOne" false) (mem "elaborateModules" false) (mem "TcDiag" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "mangleCtorCollisionsPair" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" false) (mem "evalOneWith" false) (mem "evalModulesWith" false) (mem "evalModulesRootEnvWith" false) (mem "testCapableExterns" false) (mem "funNamesOf" false) (mem "dropShadowedExp" false) (mem "lookupBinding" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" true) (mem "Engine" true) (mem "engineName" false) (mem "extractExamples" false) (mem "buildSynthResults" false) (mem "buildSynthDecls" false) (mem "buildDetailsFrom" false) (mem "doctestFailSuffix" false) (mem "hasUseDecls" false) (mem "printDoctestDetails" false) (mem "runDetails" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "synthName" false) (mem "exResultJsonFields" false))))
(DUse false (UseGroup ("tools" "native_doctest") ((mem "runNativeDoctests" false))))
(DUse false (UseGroup ("tools" "native_test_decls") ((mem "runNativeTests" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "runAllProps" false) (mem "hasProps" false) (mem "runAllPropsResults" false) (mem "PropResult" false) (mem "filterProps" false) (mem "filterPropsByName" false) (mem "propResultName" false) (mem "propResultPassed" false) (mem "propResultDetail" false))))
(DUse false (UseGroup ("tools" "test_runner") ((mem "collectTests" false) (mem "runOneTest" false) (mem "hasTests" false) (mem "uncapableExterns" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeLocated" false) (mem "projectDiagsFromTc" false) (mem "projectDiagsLoaded" false) (mem "chainKeyOf" false) (mem "desugaredModPairs" false) (mem "mkDiag" false) (mem "Severity" true) (mem "readDiagSrc" false) (mem "ppDiagCliSrc" false) (mem "ppDiagCliLines" false) (mem "srcLinesArr" false) (mem "parseErrDiag" false) (mem "Diag" false) (mem "diagIsError" false))))
(DUse true (UseGroup ("support" "util") ((mem "rootsOrDefault" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "joinNl" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "endsWith" false) (mem "splitOnChar" false) (mem "contains" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "baseOf" false) (mem "joinPath" false))))
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "Args" false) (mem "spec" false) (mem "switch" false) (mem "value" false) (mem "flag" false) (mem "flagValue" false) (mem "withStrictDash" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JInt" false) (mem "JString" false) (mem "JBool" false) (mem "jObject" false) (mem "jArray" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "splitLintNames" false))))
(DUse false (UseGroup ("string") ((mem "toInt" false))))
(DTypeSig false "substringMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substringMatch" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "runTest" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTest" ((PVar "engines") (PVar "runtimeP") (PVar "coreP") (PVar "target") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EMatch (EApp (EVar "readPreludeFile") (EVar "runtimeP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "coreP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EVar "parseErrDiag") (EVar "target")) (EVar "e"))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "exemptNotice") (EVar "exempt")) (EVar "target")) (EVar "userDecls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveAll") (EVar "engines")) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")) (EVar "exempt")))))))))))))
(DTypeSig false "typecheckExempt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "typecheckExempt" ((PVar "target") (PVar "userDecls") (PVar "tsrc")) (EIf (EApp (EVar "isNonEmptyL") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (EVar "False") (EIf (EApp (EVar "isNewVehiclePath") (EVar "target")) (EVar "False") (EIf (EVar "otherwise") (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EApp (EVar "hasTests") (EVar "userDecls"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isNewVehiclePath" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "isNewVehiclePath" ((PVar "target")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "target")) (EBlock (DoLet false false (PVar "canon") (EApp (EVar "canonicalizePath") (EVar "target"))) (DoExpr (EBinOp "||" (EBinOp "||" (EApp (EVar "hasVehicleSegment") (EVar "canon")) (EApp (EVar "underProjectTestDir") (EVar "target"))) (EApp (EVar "underMedakaRepoTestDir") (EVar "canon"))))) (EVar "False")))
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
(DFunDef false "singleFileTypeErrors" ((PVar "target") (PVar "tsrc") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EApp (EApp (EApp (EVar "analyzeLocated") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs")))))))))
(DTypeSig false "gateOfPerModule" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "gateOfPerModule" ((PCon "True") PWild PWild PWild PWild) (EVar "None"))
(DFunDef false "gateOfPerModule" ((PCon "False") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "mods") (PVar "perModule")) (EApp (EVar "renderGate") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDiagsFromTc") (EVar "True")) (EListLit)) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "mods")) (EVar "perModule"))))
(DTypeSig false "loadGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "loadGate" ((PCon "True") PWild PWild) (EVar "None"))
(DFunDef false "loadGate" ((PCon "False") (PVar "target") (PVar "le")) (EApp (EVar "renderGate") (EApp (EApp (EVar "loadErrorDiags") (EVar "target")) (EVar "le"))))
(DTypeSig false "loadErrorDiags" (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "loadErrorDiags" (PWild (PCon "LoadParseFailed" (PVar "mpath") PWild (PVar "pe"))) (EListLit (ETuple (EVar "mpath") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "mpath")) (EVar "pe"))))))
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
(DData Private "TestPair" () ((variant "TestPair" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))) (variant "TestPairErr" (ConPos (TyCon "String")))) ())
(DData Private "DoctestTrees" () ((variant "DtPair" (ConPos (TyCon "TestPair"))) (variant "DtSingle" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DData Private "Prepared" () ((variant "PreparedPair" (ConPos (TyCon "TestPair"))) (variant "PreparedInject" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DTypeSig false "prepareMulti" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Prepared")))))))))))
(DFunDef false "prepareMulti" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "exempt") (PVar "hasDoctests") (PVar "synthDecls")) (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "le")) () (ETuple (EApp (EApp (EApp (EVar "loadGate") (EVar "exempt")) (EVar "target")) (EVar "le")) (EApp (EVar "PreparedPair") (EApp (EVar "TestPairErr") (EApp (EVar "loadErrorMessage") (EVar "le")))))) (arm (PCon "Ok" (PVar "mods")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "elaborateFor") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "mods")) (EVar "exempt")) (EVar "hasDoctests")) (EVar "synthDecls")))))
(DTypeSig false "elaborateFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Prepared"))))))))))))
(DFunDef false "elaborateFor" ((PVar "rsrc") (PVar "csrc") (PVar "_target") (PVar "_roots") (PVar "mods") (PVar "exempt") (PCon "False") PWild) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EVar "desugaredModPairs") (EVar "mods"))) (arm (PTuple (PVar "coreE") (PVar "modulesE") (PVar "perModule") PWild PWild) () (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "gateOfPerModule") (EVar "exempt")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "mods")) (EVar "perModule")) (EApp (EVar "PreparedPair") (EApp (EVar "uncurryPair") (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE")))))))))))
(DFunDef false "elaborateFor" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "mods") (PVar "exempt") (PCon "True") (PVar "synthDecls")) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "gateOfCheck") (EVar "exempt")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "mods")) (EApp (EApp (EVar "PreparedInject") (EVar "mods")) (EVar "synthDecls"))))
(DTypeSig false "forcePrepared" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Prepared") (TyEffect ("IO") None (TyCon "TestPair"))))))
(DFunDef false "forcePrepared" (PWild PWild (PCon "PreparedPair" (PVar "pair"))) (EVar "pair"))
(DFunDef false "forcePrepared" ((PVar "rsrc") (PVar "csrc") (PCon "PreparedInject" (PVar "mods") (PVar "synthDecls"))) (EBlock (DoLet false false (PVar "injected") (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EApp (EVar "desugaredModPairs") (EVar "mods")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "injected")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild PWild PWild) () (EApp (EVar "uncurryPair") (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE")))))))))
(DTypeSig false "gateOfCheck" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "gateOfCheck" ((PCon "True") PWild PWild PWild PWild PWild) (EVar "None"))
(DFunDef false "gateOfCheck" ((PCon "False") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "mods")) (EApp (EVar "renderGate") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDiagsLoaded") (EVar "True")) (EListLit)) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EApp (EVar "Some") (ETuple (EApp (EVar "desugaredPreludeKey") (EVar "rsrc")) (EApp (EVar "desugaredPreludeKey") (EVar "csrc"))))) (EApp (EApp (EVar "chainKeyOf") (EVar "target")) (EVar "roots"))) (EVar "mods"))))
(DTypeSig false "uncurryPair" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyCon "TestPair")))
(DFunDef false "uncurryPair" ((PTuple (PVar "core") (PVar "mods"))) (EApp (EApp (EVar "TestPair") (EVar "core")) (EVar "mods")))
(DTypeSig false "prepareSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "TestPair"))))))))
(DFunDef false "prepareSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "roots") (PVar "userDecls")) (EBlock (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoExpr (EApp (EVar "uncurryPair") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))))))
(DTypeSig false "driveAll" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool")))))))))))))))
(DFunDef false "driveAll" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls") (PVar "exempt")) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveMulti") (EVar "engines")) (EVar "runtimeDecls")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")) (EVar "exempt")) (EIf (EVar "otherwise") (EMatch (EIf (EVar "exempt") (EVar "None") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "rsrc")) (EVar "csrc"))) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "errText")))) (DoExpr (EVar "False")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveSingle") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "driveMulti" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))))))))
(DFunDef false "driveMulti" ((PVar "engines") (PVar "runtimeDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls") (PVar "exempt")) (EBlock (DoLet false false (PVar "allExamples") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EVar "allExamples"))) (DoLet false false (PVar "synthResults") (EApp (EVar "buildSynthResults") (EVar "examples"))) (DoLet false false (PVar "synthDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults"))) (DoLet false false (PVar "gated") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prepareMulti") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "exempt")) (EApp (EVar "isNonEmptyL") (EVar "allExamples"))) (EVar "synthDecls"))) (DoExpr (EMatch (EVar "gated") (arm (PTuple (PCon "Some" (PVar "errText")) PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "errText")))) (DoExpr (EVar "False")))) (arm (PTuple (PCon "None") (PVar "prepared")) () (EIf (EApp (EApp (EApp (EVar "filterMatchedNothing") (EVar "filterOpt")) (EVar "tsrc")) (EVar "userDecls")) (EBlock (DoLet false false PWild (EApp (EVar "filterMatchedNothingNotice") (EVar "target"))) (DoExpr (EVar "False"))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EVar "forcePrepared") (EVar "rsrc")) (EVar "csrc")) (EVar "prepared"))) (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "engines")) (EApp (EVar "DtPair") (EVar "pair"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProps") (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDecls") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk"))))))))))
(DTypeSig false "driveSingle" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Bool"))))))))))))
(DFunDef false "driveSingle" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls")) (EBlock (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoExpr (EIf (EApp (EApp (EApp (EVar "filterMatchedNothing") (EVar "filterOpt")) (EVar "tsrc")) (EVar "userDecls")) (EBlock (DoLet false false PWild (EApp (EVar "filterMatchedNothingNotice") (EVar "target"))) (DoExpr (EVar "False"))) (EBlock (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "engines")) (EApp (EApp (EApp (EApp (EApp (EVar "DtSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EApp (EVar "buildSynthResults") (EVar "examples")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EApp (EVar "hasTests") (EVar "userDecls"))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EApp (EApp (EVar "prepareSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProps") (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDecls") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk")))) (EVar "doctestsOk"))))))))
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
(DFunDef false "runChosenOn" ((PCon "EngNative") (PVar "_trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runNativeDoctests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")) (EApp (EVar "not") (EVar "exempt"))))))
(DTypeSig false "runChosen" (TyFun (TyCon "DoctestTrees") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult"))))))
(DFunDef false "runChosen" ((PCon "DtPair" (PCon "TestPairErr" (PVar "e"))) (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Err") (EVar "e"))) (EVar "synthResults")) (EVar "examples")))
(DFunDef false "runChosen" ((PCon "DtPair" (PCon "TestPair" (PVar "coreM") (PVar "modsM"))) (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))
(DFunDef false "runChosen" ((PCon "DtSingle" (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "roots") (PVar "userDecls")) (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "allUser") (EBinOp "++" (EVar "userDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults")))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EApp (EVar "funNamesOf") (EVar "allUser"))) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateOne") (EVar "runtimeDecls")) (EVar "livePrelude")) (ETuple (EVar "rootId") (EVar "allUser")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalOneWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EListLit)) (ETuple (ELit (LString "__main__")) (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))
(DTypeSig false "renderExamples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderExamples" ((PVar "env") (PVar "examples")) (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (ELit (LInt 0))) (EVar "examples")))
(DTypeSig false "renderExamplesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "renderExamplesGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "renderExamplesGo" ((PVar "env") (PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "renderOneExample") (EVar "env")) (EVar "i")) (EVar "ex")) (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "renderOneExample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderOneExample" ((PVar "env") (PVar "i") (PVar "ex")) (EMatch (EApp (EApp (EVar "lookupBinding") (EApp (EVar "synthName") (EVar "i"))) (EVar "env")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "could not evaluate: ")) (EApp (EVar "exampleInput") (EVar "ex"))))) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))))))
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
(DFunDef false "collectPropLines" ((PCons (PCon "DProp" PWild (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "exprLineLocal") (EVar "body"))) (EApp (EVar "collectPropLines") (EVar "rest"))))
(DFunDef false "collectPropLines" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectPropLines") (EVar "rest")))
(DTypeSig false "exprLineLocal" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprLineLocal" ((PCon "ELoc" (PCon "Loc" PWild (PVar "l") PWild PWild PWild) PWild)) (EVar "l"))
(DFunDef false "exprLineLocal" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "exprLineLocal") (EVar "f")))
(DFunDef false "exprLineLocal" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "exprLineLocal") (EVar "e")))
(DFunDef false "exprLineLocal" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "exprLineLocal") (EVar "e")))
(DFunDef false "exprLineLocal" (PWild) (ELit (LInt 0)))
(DTypeSig false "elaborateModulesMangled" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "elaborateModulesMangled" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild PWild PWild) () (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE"))))))
(DTypeSig false "runProps" (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runProps" ((PVar "pair") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EVar "True") (EIf (EVar "otherwise") (EMatch (EVar "pair") (arm (PCon "TestPairErr" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "TestPair" (PVar "coreM") (PVar "modsM")) () (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runAllProps") (EVar "cases")) (EVar "filterOpt")) (EVar "target")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EVar "env")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "elaboratedRootProps" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "elaboratedRootProps" ((PVar "modules") (PVar "userDecls")) (EMatch (EApp (EVar "lastModule") (EVar "modules")) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls"))))
(DTypeSig false "lastModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "lastModule" ((PList)) (EVar "None"))
(DFunDef false "lastModule" ((PList (PTuple PWild (PVar "decls")))) (EApp (EVar "Some") (EVar "decls")))
(DFunDef false "lastModule" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModule") (EVar "rest")))
(DTypeSig false "runTestDecls" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestDecls" ((PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestEngines") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runTestEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestEngines" ((PList (PVar "e")) (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestsOn") (EVar "e")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")))
(DFunDef false "runTestEngines" ((PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestEnginesTagged") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")))
(DTypeSig false "runTestEnginesTagged" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestEnginesTagged" ((PList) PWild PWild PWild PWild PWild PWild) (EVar "True"))
(DFunDef false "runTestEnginesTagged" ((PCons (PVar "e") (PVar "rest")) (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "-- ")) (EApp (EVar "display") (EApp (EVar "engineName") (EVar "e")))) (ELit (LString " --"))))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestsOn") (EVar "e")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))) (DoLet false false (PVar "restOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestEnginesTagged") (EVar "rest")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))) (DoExpr (EBinOp "&&" (EVar "ok") (EVar "restOk")))))
(DTypeSig false "runTestsOn" (TyFun (TyCon "Engine") (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestsOn" ((PCon "EngInterp") (PCon "TestPairErr" (PVar "e")) (PVar "_runtimeDecls") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PVar "_filterOpt")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False"))))
(DFunDef false "runTestsOn" ((PCon "EngInterp") (PCon "TestPair" (PVar "coreM") (PVar "modsM")) (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EVar "gatedReportTests") (EVar "target")) (EBinOp "++" (EBinOp "++" (EVar "runtimeDecls") (EVar "coreM")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modsM")))) (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EApp (EApp (EApp (EApp (EVar "rootTestsOf") (EVar "filterOpt")) (EVar "tsrc")) (EVar "modsM")) (EVar "userDecls"))))
(DFunDef false "runTestsOn" ((PCon "EngNative") (PVar "_pair") (PVar "_runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EVar "runTestDeclsNative") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")))
(DTypeSig false "rootTestsOf" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))))
(DFunDef false "rootTestsOf" ((PVar "filterOpt") (PVar "tsrc") (PVar "modsM") (PVar "userDecls")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))))))
(DTypeSig false "runTestDeclsNative" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runTestDeclsNative" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "tests") (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EVar "nativeRawTests") (EVar "tsrc")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running tests in ")) (EVar "target")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EApp (EApp (EApp (EVar "reportNativeTests") (EVar "target")) (EVar "tests")) (EApp (EApp (EApp (EApp (EApp (EVar "runNativeTests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "tests")) (EApp (EVar "not") (EVar "exempt")))))))
(DTypeSig false "nativeRawTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "nativeRawTests" ((PVar "tsrc")) (EApp (EVar "collectTests") (EApp (EVar "parseLocated") (EVar "tsrc"))))
(DTypeSig false "reportNativeTests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "ExResult")) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "reportNativeTests" ((PVar "target") (PVar "tests") (PVar "results")) (EBlock (DoLet false false (PTuple (PVar "passed") (PVar "failed") (PVar "errors")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestLoop") (EVar "target")) (EVar "tests")) (EVar "results")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reportTestSummary") (EVar "target")) (EVar "passed")) (EVar "failed")) (EVar "errors")))))
(DTypeSig false "nativeTestLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "ExResult")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))))))))
(DFunDef false "nativeTestLoop" (PWild (PList) PWild (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EVar "errors")))
(DFunDef false "nativeTestLoop" (PWild (PCons PWild PWild) (PList) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EVar "errors")))
(DFunDef false "nativeTestLoop" ((PVar "target") (PCons (PTuple (PVar "name") (PVar "line") PWild) (PVar "rest")) (PCons (PVar "r") (PVar "rRest")) (PVar "passed") (PVar "failed") (PVar "errors")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "printTestRunning") (EVar "target")) (EVar "line")) (EVar "name"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "printTestVerdict") (EVar "target")) (EVar "line")) (EVar "name")) (EVar "r"))) (DoLet false false (PTuple (PVar "p") (PVar "f") (PVar "e")) (EApp (EApp (EApp (EApp (EVar "tallyTest") (EVar "r")) (EVar "passed")) (EVar "failed")) (EVar "errors"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestLoop") (EVar "target")) (EVar "rest")) (EVar "rRest")) (EVar "p")) (EVar "f")) (EVar "e")))))
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
(DTypeSig false "gatedReportTests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "gatedReportTests" ((PVar "target") (PVar "corpus") (PVar "env") (PVar "tests")) (EMatch (EApp (EApp (EApp (EVar "uncapableExterns") (EVar "corpus")) (EVar "env")) (EVar "tests")) (arm (PList) () (EApp (EApp (EApp (EVar "reportTests") (EVar "target")) (EVar "env")) (EVar "tests"))) (arm (PVar "names") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "uncapableExternsMsg") (EVar "target")) (EVar "names")))) (DoExpr (EVar "False"))))))
(DTypeSig false "uncapableExternsMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "uncapableExternsMsg" ((PVar "target") (PVar "names")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": `test \"…\"` declarations here reach "))) (EApp (EVar "display") (EApp (EVar "externWord") (EVar "names")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "joinCommas") (EVar "names")))) (ELit (LString ", which `medaka test` does not provide under the interpreter — its capability policy covers the clock, allocation counts and stderr only, so no filesystem, environment, stdin, network or subprocess extern is bound. No test was run. Run these tests natively instead: `medaka test --native "))) (EApp (EVar "display") (EVar "target"))) (ELit (LString "`."))))
(DTypeSig false "externWord" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "externWord" ((PList PWild)) (ELit (LString "the extern")))
(DFunDef false "externWord" (PWild) (ELit (LString "the externs")))
(DTypeSig false "joinCommas" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinCommas" ((PList)) (ELit (LString "")))
(DFunDef false "joinCommas" ((PList (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))))
(DFunDef false "joinCommas" ((PCons (PVar "n") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`, "))) (EApp (EVar "joinCommas") (EVar "rest"))))
(DTypeSig false "reportTests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "reportTests" ((PVar "target") (PVar "env") (PVar "tests")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running tests in ")) (EVar "target")))) (DoLet false false (PTuple (PVar "passed") (PVar "failed") (PVar "errors")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reportTestSummary") (EVar "target")) (EVar "passed")) (EVar "failed")) (EVar "errors")))))
(DTypeSig false "reportTestSummary" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "reportTestSummary" ((PVar "target") (PVar "passed") (PVar "failed") (PVar "errors")) (EBlock (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EVar "passed") (EVar "failed")) (EVar "errors"))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " passed"))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EVar "testFailSuffix") (EVar "failed")) (EVar "errors")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EVar "failed") (ELit (LInt 0))) (EBinOp "==" (EVar "errors") (ELit (LInt 0)))))))
(DTypeSig false "printTestRunning" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "printTestRunning" ((PVar "target") (PVar "line") (PVar "name")) (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  running ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "printTestVerdict" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "ExResult") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "printTestVerdict" ((PVar "target") (PVar "line") (PVar "name") (PVar "result")) (EBlock (DoLet false false (PVar "loc") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString "")))) (DoExpr (EMatch (EVar "result") (arm (PCon "Pass" PWild PWild) () (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ok   ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (arm (PCon "Fail" (PVar "msg") PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg")))))) (arm (PCon "Errored" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg"))))))))))
(DTypeSig false "tallyTest" (TyFun (TyCon "ExResult") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "tallyTest" ((PCon "Pass" PWild PWild) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EBinOp "+" (EVar "passed") (ELit (LInt 1))) (EVar "failed") (EVar "errors")))
(DFunDef false "tallyTest" ((PCon "Fail" PWild PWild PWild) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EBinOp "+" (EVar "failed") (ELit (LInt 1))) (EVar "errors")))
(DFunDef false "tallyTest" ((PCon "Errored" PWild) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EBinOp "+" (EVar "errors") (ELit (LInt 1)))))
(DTypeSig false "runTestLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))))))))
(DFunDef false "runTestLoop" (PWild PWild (PList) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EVar "errors")))
(DFunDef false "runTestLoop" ((PVar "target") (PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest")) (PVar "passed") (PVar "failed") (PVar "errors")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "printTestRunning") (EVar "target")) (EVar "line")) (EVar "name"))) (DoLet false false (PVar "result") (EApp (EApp (EVar "runOneTest") (EVar "env")) (EVar "body"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "printTestVerdict") (EVar "target")) (EVar "line")) (EVar "name")) (EVar "result"))) (DoLet false false (PTuple (PVar "p") (PVar "f") (PVar "e")) (EApp (EApp (EApp (EApp (EVar "tallyTest") (EVar "result")) (EVar "passed")) (EVar "failed")) (EVar "errors"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EVar "p")) (EVar "f")) (EVar "e")))))
(DTypeSig false "testFailSuffix" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "testFailSuffix" ((PVar "failed") (PVar "errors")) (EIf (EBinOp "||" (EBinOp ">" (EVar "failed") (ELit (LInt 0))) (EBinOp ">" (EVar "errors") (ELit (LInt 0)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "errors")))) (ELit (LString " errors)"))) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "runTestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))
(DFunDef false "runTestReport" ((PVar "engines") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "target") (PVar "tsrc") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportMulti") (EVar "engines")) (EVar "runtimeDecls")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (EVar "userDecls")) (EVar "exempt")) (EMatch (EIf (EVar "exempt") (EVar "None") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (arm (PCon "Some" (PVar "errText")) () (ETuple (EApp (EVar "Some") (EVar "errText")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportSingle") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (EVar "userDecls")) (EVar "exempt"))))))))
(DTypeSig false "reportMulti" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool"))))))))))))))))
(DFunDef false "reportMulti" ((PVar "engines") (PVar "runtimeDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls") (PVar "userDecls") (PVar "exempt")) (EBlock (DoLet false false (PVar "allExamples") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EVar "allExamples"))) (DoLet false false (PVar "synthResults") (EApp (EVar "buildSynthResults") (EVar "examples"))) (DoLet false false (PVar "prepared") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prepareMulti") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "exempt")) (EApp (EVar "isNonEmptyL") (EVar "allExamples"))) (EApp (EVar "buildSynthDecls") (EVar "synthResults")))) (DoExpr (EMatch (EVar "prepared") (arm (PTuple (PCon "Some" (PVar "errText")) PWild) () (ETuple (EApp (EVar "Some") (EVar "errText")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PTuple (PCon "None") (PVar "prepared")) () (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EVar "forcePrepared") (EVar "rsrc")) (EVar "csrc")) (EVar "prepared"))) (DoExpr (ETuple (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReport") (EVar "engines")) (EApp (EVar "DtPair") (EVar "pair"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReport") (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportTestDecls") (EVar "includeTestDecls")) (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "exempt")))))))))
(DTypeSig false "reportSingle" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))))
(DFunDef false "reportSingle" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls") (PVar "userDecls") (PVar "exempt")) (EBlock (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoLet false false (PVar "doctestRuns") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReport") (EVar "engines")) (EApp (EApp (EApp (EApp (EApp (EVar "DtSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EApp (EVar "buildSynthResults") (EVar "examples")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EBinOp "&&" (EVar "includeTestDecls") (EApp (EVar "hasTests") (EVar "userDecls")))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EApp (EApp (EVar "prepareSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (DoExpr (ETuple (EVar "None") (EVar "doctestRuns") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReport") (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportTestDecls") (EVar "includeTestDecls")) (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "exempt")))) (ETuple (EVar "None") (EVar "doctestRuns") (EListLit) (EListLit) (EVar "exempt"))))))
(DTypeSig false "reportTestDecls" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))))))))
(DFunDef false "reportTestDecls" ((PCon "False") PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "reportTestDecls" ((PCon "True") (PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReport") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")))
(DTypeSig false "doctestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))))))))))))
(DFunDef false "doctestReport" ((PVar "engines") (PVar "_trees") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PList) (PVar "_synthResults")) (EApp (EVar "emptyDoctestRuns") (EVar "engines")))
(DFunDef false "doctestReport" ((PVar "engines") (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "engines")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))
(DTypeSig false "emptyDoctestRuns" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult")))))
(DFunDef false "emptyDoctestRuns" ((PList)) (EListLit))
(DFunDef false "emptyDoctestRuns" ((PCons (PVar "e") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (EApp (EVar "emptyDoctestRuns") (EVar "rest"))))
(DTypeSig false "doctestReportGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))))))))))))
(DFunDef false "doctestReportGo" ((PList) PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "doctestReportGo" ((PCons (PVar "e") (PVar "rest")) (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "rest")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))))
(DTypeSig false "propsReport" (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "propsReport" ((PVar "pair") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EListLit) (EIf (EVar "otherwise") (EMatch (EVar "pair") (arm (PCon "TestPairErr" PWild) () (EListLit)) (arm (PCon "TestPair" (PVar "coreM") (PVar "modsM")) () (EApp (EApp (EApp (EApp (EApp (EVar "runAllPropsResults") (EVar "cases")) (EVar "filterOpt")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "testDeclsReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReport" ((PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportEngines") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "testDeclsReportEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReportEngines" ((PList) PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "testDeclsReportEngines" ((PCons (PVar "e") (PVar "rest")) (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "tagWithEngine") (EVar "e")) (EVar "t")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportOn") (EVar "e")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportEngines") (EVar "rest")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))))
(DTypeSig false "tagWithEngine" (TyFun (TyCon "Engine") (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")) (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))
(DFunDef false "tagWithEngine" ((PVar "e") (PTuple (PVar "name") (PVar "line") (PVar "result"))) (ETuple (EVar "e") (EVar "name") (EVar "line") (EVar "result")))
(DTypeSig false "testDeclsReportOn" (TyFun (TyCon "Engine") (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReportOn" ((PCon "EngInterp") (PCon "TestPairErr" PWild) (PVar "_runtimeDecls") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PVar "_filterOpt")) (EListLit))
(DFunDef false "testDeclsReportOn" ((PCon "EngInterp") (PCon "TestPair" (PVar "coreM") (PVar "modsM")) (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EVar "gatedTestsCollect") (EVar "target")) (EBinOp "++" (EBinOp "++" (EVar "runtimeDecls") (EVar "coreM")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modsM")))) (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EApp (EApp (EApp (EApp (EVar "rootTestsOf") (EVar "filterOpt")) (EVar "tsrc")) (EVar "modsM")) (EVar "userDecls"))))
(DFunDef false "testDeclsReportOn" ((PCon "EngNative") (PVar "_pair") (PVar "_runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "tests") (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EVar "nativeRawTests") (EVar "tsrc")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EApp (EApp (EVar "zipTestResults") (EVar "tests")) (EApp (EApp (EApp (EApp (EApp (EVar "runNativeTests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "tests")) (EApp (EVar "not") (EVar "exempt")))))))
(DTypeSig false "zipTestResults" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "ExResult")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))
(DFunDef false "zipTestResults" ((PList) PWild) (EListLit))
(DFunDef false "zipTestResults" ((PCons PWild PWild) (PList)) (EListLit))
(DFunDef false "zipTestResults" ((PCons (PTuple (PVar "name") (PVar "line") PWild) (PVar "rest")) (PCons (PVar "r") (PVar "rRest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EVar "r")) (EApp (EApp (EVar "zipTestResults") (EVar "rest")) (EVar "rRest"))))
(DTypeSig false "gatedTestsCollect" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))))
(DFunDef false "gatedTestsCollect" ((PVar "target") (PVar "corpus") (PVar "env") (PVar "tests")) (EMatch (EApp (EApp (EApp (EVar "uncapableExterns") (EVar "corpus")) (EVar "env")) (EVar "tests")) (arm (PList) () (EApp (EApp (EVar "runTestsCollect") (EVar "env")) (EVar "tests"))) (arm (PVar "names") () (EBlock (DoLet false false (PVar "msg") (EApp (EApp (EVar "uncapableExternsMsg") (EVar "target")) (EVar "names"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "t")) (ETuple (EApp (EVar "fst3") (EVar "t")) (EApp (EVar "snd3") (EVar "t")) (EApp (EVar "Errored") (EVar "msg"))))) (EVar "tests")))))))
(DTypeSig false "snd3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "b")))
(DFunDef false "snd3" ((PTuple PWild (PVar "b") PWild)) (EVar "b"))
(DTypeSig false "runTestsCollect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))
(DFunDef false "runTestsCollect" (PWild (PList)) (EListLit))
(DFunDef false "runTestsCollect" ((PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EApp (EApp (EVar "runOneTest") (EVar "env")) (EVar "body"))) (EApp (EApp (EVar "runTestsCollect") (EVar "env")) (EVar "rest"))))
(DTypeSig true "testHelpText" (TyCon "String"))
(DFunDef false "testHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka test — Run doctests + property tests\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka test [--native | --engines eval,native] [--json] [--filter <substring>]\n")) (ELit (LString "              [--seed <n>] [--cases <n>] [file.mdk | dir]\n")) (ELit (LString "\n")) (ELit (LString "  --native            run doctests through a compiled native binary\n")) (ELit (LString "                      instead of the interpreter (shorthand for\n")) (ELit (LString "                      --engines native)\n")) (ELit (LString "  --engines e1,e2,...  run the listed engine set (known: eval, native);\n")) (ELit (LString "                      exit code is the AND across engines\n")) (ELit (LString "  --json               emit a {\"file\":...,\"doctests\":...,\"properties\":...,\n")) (ELit (LString "                      \"tests\":...,\"summary\":...} JSON object instead of\n")) (ELit (LString "                      human text (single file.mdk target only; agrees with\n")) (ELit (LString "                      the human report's pass/fail counts on all three\n")) (ELit (LString "                      phases)\n")) (ELit (LString "  --filter <substring> restrict to doctests/`test \"…\"`/`prop \"…\"` whose\n")) (ELit (LString "                      name (or, for a doctest, input expression) contains\n")) (ELit (LString "                      <substring>\n")) (ELit (LString "  --seed <n>           seed the property-test RNG (printed on every prop\n")) (ELit (LString "                      failure so the counterexample is replayable); never\n")) (ELit (LString "                      affects a program under test's own random draws\n")) (ELit (LString "  --cases <n>           run each property with <n> generated cases\n")) (ELit (LString "                      instead of the default 100\n")) (ELit (LString "\n")) (ELit (LString "--native and --engines are mutually exclusive. With neither, the default\n")) (ELit (LString "is the interpreter (eval) alone. A file.mdk or dir target is required.\n")))))
(DTypeSig true "testArgSpec" (TyCon "ArgSpec"))
(DFunDef false "testArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "test"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--native")))) (ELit (LString "shorthand for --engines native"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--engines")))) (ELit (LString "eval,native"))) (ELit (LString "engines to run each example under"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--filter")))) (ELit (LString "SUBSTRING"))) (ELit (LString "run only matching examples"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--seed")))) (ELit (LString "N"))) (ELit (LString "seed the property RNG"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--cases")))) (ELit (LString "N"))) (ELit (LString "property cases per test")))))))
(DTypeSig true "parseTestIntFlag" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "parseTestIntFlag" ((PVar "nm") (PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (EVar "nm")) (EVar "a")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Some" (PVar "s")) () (EMatch (EApp (EVar "toInt") (EVar "s")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "n")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "nm"))) (ELit (LString " requires an integer value, got '"))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "'")))))))))
(DTypeSig true "parseTestCasesFlag" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "parseTestCasesFlag" ((PVar "a")) (EMatch (EApp (EApp (EVar "parseTestIntFlag") (ELit (LString "--cases"))) (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PCon "None")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Ok" (PCon "Some" (PVar "n"))) () (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--cases requires a positive integer value, got '")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "'")))) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "n")))))))
(DTypeSig true "parseTestEngines" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseTestEngines" ((PVar "a")) (EMatch (ETuple (EApp (EApp (EVar "flagValue") (ELit (LString "--engines"))) (EVar "a")) (EApp (EApp (EVar "flag") (ELit (LString "--native"))) (EVar "a"))) (arm (PTuple (PCon "Some" PWild) (PCon "True")) () (EApp (EVar "Err") (ELit (LString "--native and --engines are mutually exclusive; --native is shorthand for --engines native")))) (arm (PTuple (PCon "Some" (PVar "spec")) (PCon "False")) () (EApp (EVar "parseEngineList") (EVar "spec"))) (arm (PTuple (PCon "None") (PCon "True")) () (EApp (EVar "Ok") (EListLit (EVar "EngNative")))) (arm (PTuple (PCon "None") (PCon "False")) () (EApp (EVar "Ok") (EListLit (EVar "EngInterp"))))))
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
(DFunDef false "cliPropJson" ((PVar "p")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "propResultName") (EVar "p")))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LString "pass")) (ELit (LString "fail"))))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EApp (EVar "propResultDetail") (EVar "p")))))))
(DTypeSig false "cliTestJson" (TyFun (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "cliTestJson" ((PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "result"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "engineName") (EVar "engine"))))) (EApp (EVar "exResultJsonFields") (EVar "result")))))
(DTypeSig false "cliTypeErrorField" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliTypeErrorField" ((PCon "None")) (EListLit))
(DFunDef false "cliTypeErrorField" ((PCon "Some" (PVar "errText"))) (EListLit (ETuple (ELit (LString "typeError")) (EApp (EVar "JString") (EVar "errText")))))
(DTypeSig false "cliTypecheckSkippedField" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliTypecheckSkippedField" ((PCon "False")) (EListLit))
(DFunDef false "cliTypecheckSkippedField" ((PCon "True")) (EListLit (ETuple (ELit (LString "typecheckSkipped")) (EApp (EVar "JBool") (EVar "True")))))
(DTypeSig true "cliTestReportJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyFun (TyCon "Bool") (TyCon "Json"))))))))
(DFunDef false "cliTestReportJson" ((PVar "path") (PVar "typeError") (PVar "runs") (PVar "props") (PVar "tests") (PVar "typecheckSkipped")) (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path")))) (EApp (EVar "cliTypeErrorField") (EVar "typeError"))) (EApp (EVar "cliTypecheckSkippedField") (EVar "typecheckSkipped"))) (EListLit (ETuple (ELit (LString "doctests")) (EApp (EVar "cliDoctestsJson") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "cliPropJson")) (EVar "props")))) (ETuple (ELit (LString "tests")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "cliTestJson")) (EVar "tests")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "cliCountPassProps") (EVar "props"))) (EApp (EVar "cliCountPassTests") (EVar "tests"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "runErrors") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (EApp (EVar "cliCountFailProps") (EVar "props"))) (EApp (EVar "cliCountFailTests") (EVar "tests"))))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EApp (EApp (EVar "cliTestReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")) (EVar "tests")))))))))))
(DTypeSig true "checkTestMdkRoster" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "checkTestMdkRoster" ((PVar "root") (PVar "targets") (PVar "files")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "git"))) (EBinOp "++" (EListLit (ELit (LString "ls-files")) (ELit (LString "--full-name")) (ELit (LString "--"))) (EVar "targets"))) (arm (PCon "Err" PWild) () (EVar "True")) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "tracked") (EApp (EApp (EVar "filterList") (EApp (EVar "endsWith") (ELit (LString "_test.mdk")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitNl") (EVar "out"))))) (DoLet false false (PVar "relFiles") (EApp (EApp (EVar "map") (EApp (EVar "stripRootPrefix") (EVar "root"))) (EVar "files"))) (DoLet false false (PVar "missing") (EApp (EApp (EVar "filterList") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "t")) (EVar "relFiles"))))) (EVar "tracked"))) (DoExpr (EMatch (EVar "missing") (arm (PList) () (EVar "True")) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: git-tracked but not discovered: ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "missing")))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))) (arm (PCon "Ok" (PTuple PWild PWild PWild)) () (EVar "True"))))
(DTypeSig false "stripRootPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripRootPrefix" ((PVar "root") (PVar "p")) (EBlock (DoLet false false (PVar "prefix") (EBinOp "++" (EVar "root") (ELit (LString "/")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "p")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "p"))) (EVar "p")) (EVar "p")))))
(DTypeSig false "testChildArgs" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "testChildArgs" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "f")) (EBinOp "++" (EListLit (ELit (LString "test")) (EVar "f") (ELit (LString "--engines")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "engineName")) (EVar "engines"))) (ELit (LString "--cases")) (EApp (EVar "intToString") (EVar "cases"))) (EMatch (EVar "filterOpt") (arm (PCon "Some" (PVar "s")) () (EListLit (ELit (LString "--filter")) (EVar "s"))) (arm (PCon "None") () (EListLit)))))
(DTypeSig true "testFilesGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "testFilesGo" (PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "testFilesGo" ((PVar "engines") (PVar "rtPath") (PVar "corePath") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EVar "executablePath") (ELit LUnit)))) (DoLet false false (PVar "args") (EApp (EApp (EApp (EApp (EVar "testChildArgs") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "f"))) (DoLet false false (PVar "ok") (EMatch (EApp (EApp (EVar "runCommand") (EVar "medaka")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EVar "display") (EVar "f"))) (ELit (LString ": failed to start test runner: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "out"))) (DoLet false false PWild (EApp (EVar "flushStdout") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EVar "True") (EBlock (DoLet false false PWild (EApp (EVar "ePutStr") (EVar "err"))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EVar "display") (EVar "f"))) (ELit (LString ": DEAD (child exited "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))))) (DoExpr (EVar "False"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EApp (EVar "not") (EVar "ok")))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DData" false) (mem "DInterface" false) (mem "DProp" false) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseResult" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "desugaredPreludeKey" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgramFilesLocatedE" false) (mem "loadErrorMessage" false) (mem "LoadError" true) (mem "entrySearchRoots" false) (mem "canonicalPathId" false) (mem "readDeps" false) (mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "readPreludeFile" false) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateOne" false) (mem "elaborateModules" false) (mem "TcDiag" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "mangleCtorCollisionsPair" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" false) (mem "evalOneWith" false) (mem "evalModulesWith" false) (mem "evalModulesRootEnvWith" false) (mem "testCapableExterns" false) (mem "funNamesOf" false) (mem "dropShadowedExp" false) (mem "lookupBinding" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" true) (mem "Engine" true) (mem "engineName" false) (mem "extractExamples" false) (mem "buildSynthResults" false) (mem "buildSynthDecls" false) (mem "buildDetailsFrom" false) (mem "doctestFailSuffix" false) (mem "hasUseDecls" false) (mem "printDoctestDetails" false) (mem "runDetails" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "synthName" false) (mem "exResultJsonFields" false))))
(DUse false (UseGroup ("tools" "native_doctest") ((mem "runNativeDoctests" false))))
(DUse false (UseGroup ("tools" "native_test_decls") ((mem "runNativeTests" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "runAllProps" false) (mem "hasProps" false) (mem "runAllPropsResults" false) (mem "PropResult" false) (mem "filterProps" false) (mem "filterPropsByName" false) (mem "propResultName" false) (mem "propResultPassed" false) (mem "propResultDetail" false))))
(DUse false (UseGroup ("tools" "test_runner") ((mem "collectTests" false) (mem "runOneTest" false) (mem "hasTests" false) (mem "uncapableExterns" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeLocated" false) (mem "projectDiagsFromTc" false) (mem "projectDiagsLoaded" false) (mem "chainKeyOf" false) (mem "desugaredModPairs" false) (mem "mkDiag" false) (mem "Severity" true) (mem "readDiagSrc" false) (mem "ppDiagCliSrc" false) (mem "ppDiagCliLines" false) (mem "srcLinesArr" false) (mem "parseErrDiag" false) (mem "Diag" false) (mem "diagIsError" false))))
(DUse true (UseGroup ("support" "util") ((mem "rootsOrDefault" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "joinNl" false) (mem "isNonEmptyL" false) (mem "filterList" false) (mem "endsWith" false) (mem "splitOnChar" false) (mem "contains" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "baseOf" false) (mem "joinPath" false))))
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "Args" false) (mem "spec" false) (mem "switch" false) (mem "value" false) (mem "flag" false) (mem "flagValue" false) (mem "withStrictDash" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JInt" false) (mem "JString" false) (mem "JBool" false) (mem "jObject" false) (mem "jArray" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "splitLintNames" false))))
(DUse false (UseGroup ("string") ((mem "toInt" false))))
(DTypeSig false "substringMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substringMatch" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "runTest" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTest" ((PVar "engines") (PVar "runtimeP") (PVar "coreP") (PVar "target") (PVar "roots") (PVar "cases") (PVar "filterOpt")) (EMatch (EApp (EVar "readPreludeFile") (EVar "runtimeP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "coreP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EVar "parseErrDiag") (EVar "target")) (EVar "e"))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "exemptNotice") (EVar "exempt")) (EVar "target")) (EVar "userDecls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveAll") (EVar "engines")) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")) (EVar "exempt")))))))))))))
(DTypeSig false "typecheckExempt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "typecheckExempt" ((PVar "target") (PVar "userDecls") (PVar "tsrc")) (EIf (EApp (EVar "isNonEmptyL") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (EVar "False") (EIf (EApp (EVar "isNewVehiclePath") (EVar "target")) (EVar "False") (EIf (EVar "otherwise") (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EApp (EVar "hasTests") (EVar "userDecls"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isNewVehiclePath" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "isNewVehiclePath" ((PVar "target")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "target")) (EBlock (DoLet false false (PVar "canon") (EApp (EVar "canonicalizePath") (EVar "target"))) (DoExpr (EBinOp "||" (EBinOp "||" (EApp (EVar "hasVehicleSegment") (EVar "canon")) (EApp (EVar "underProjectTestDir") (EVar "target"))) (EApp (EVar "underMedakaRepoTestDir") (EVar "canon"))))) (EVar "False")))
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
(DFunDef false "singleFileTypeErrors" ((PVar "target") (PVar "tsrc") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EApp (EApp (EApp (EVar "analyzeLocated") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs")))))))))
(DTypeSig false "gateOfPerModule" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "gateOfPerModule" ((PCon "True") PWild PWild PWild PWild) (EVar "None"))
(DFunDef false "gateOfPerModule" ((PCon "False") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "mods") (PVar "perModule")) (EApp (EVar "renderGate") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDiagsFromTc") (EVar "True")) (EListLit)) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "mods")) (EVar "perModule"))))
(DTypeSig false "loadGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "loadGate" ((PCon "True") PWild PWild) (EVar "None"))
(DFunDef false "loadGate" ((PCon "False") (PVar "target") (PVar "le")) (EApp (EVar "renderGate") (EApp (EApp (EVar "loadErrorDiags") (EVar "target")) (EVar "le"))))
(DTypeSig false "loadErrorDiags" (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "loadErrorDiags" (PWild (PCon "LoadParseFailed" (PVar "mpath") PWild (PVar "pe"))) (EListLit (ETuple (EVar "mpath") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "mpath")) (EVar "pe"))))))
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
(DData Private "TestPair" () ((variant "TestPair" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))) (variant "TestPairErr" (ConPos (TyCon "String")))) ())
(DData Private "DoctestTrees" () ((variant "DtPair" (ConPos (TyCon "TestPair"))) (variant "DtSingle" (ConPos (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DData Private "Prepared" () ((variant "PreparedPair" (ConPos (TyCon "TestPair"))) (variant "PreparedInject" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DTypeSig false "prepareMulti" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Prepared")))))))))))
(DFunDef false "prepareMulti" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "exempt") (PVar "hasDoctests") (PVar "synthDecls")) (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "le")) () (ETuple (EApp (EApp (EApp (EVar "loadGate") (EVar "exempt")) (EVar "target")) (EVar "le")) (EApp (EVar "PreparedPair") (EApp (EVar "TestPairErr") (EApp (EVar "loadErrorMessage") (EVar "le")))))) (arm (PCon "Ok" (PVar "mods")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "elaborateFor") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "mods")) (EVar "exempt")) (EVar "hasDoctests")) (EVar "synthDecls")))))
(DTypeSig false "elaborateFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Prepared"))))))))))))
(DFunDef false "elaborateFor" ((PVar "rsrc") (PVar "csrc") (PVar "_target") (PVar "_roots") (PVar "mods") (PVar "exempt") (PCon "False") PWild) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EVar "desugaredModPairs") (EVar "mods"))) (arm (PTuple (PVar "coreE") (PVar "modulesE") (PVar "perModule") PWild PWild) () (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "gateOfPerModule") (EVar "exempt")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "mods")) (EVar "perModule")) (EApp (EVar "PreparedPair") (EApp (EVar "uncurryPair") (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE")))))))))))
(DFunDef false "elaborateFor" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "mods") (PVar "exempt") (PCon "True") (PVar "synthDecls")) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "gateOfCheck") (EVar "exempt")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "mods")) (EApp (EApp (EVar "PreparedInject") (EVar "mods")) (EVar "synthDecls"))))
(DTypeSig false "forcePrepared" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Prepared") (TyEffect ("IO") None (TyCon "TestPair"))))))
(DFunDef false "forcePrepared" (PWild PWild (PCon "PreparedPair" (PVar "pair"))) (EVar "pair"))
(DFunDef false "forcePrepared" ((PVar "rsrc") (PVar "csrc") (PCon "PreparedInject" (PVar "mods") (PVar "synthDecls"))) (EBlock (DoLet false false (PVar "injected") (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EApp (EVar "desugaredModPairs") (EVar "mods")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "injected")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild PWild PWild) () (EApp (EVar "uncurryPair") (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE")))))))))
(DTypeSig false "gateOfCheck" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))))
(DFunDef false "gateOfCheck" ((PCon "True") PWild PWild PWild PWild PWild) (EVar "None"))
(DFunDef false "gateOfCheck" ((PCon "False") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "mods")) (EApp (EVar "renderGate") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectDiagsLoaded") (EVar "True")) (EListLit)) (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EApp (EVar "Some") (ETuple (EApp (EVar "desugaredPreludeKey") (EVar "rsrc")) (EApp (EVar "desugaredPreludeKey") (EVar "csrc"))))) (EApp (EApp (EVar "chainKeyOf") (EVar "target")) (EVar "roots"))) (EVar "mods"))))
(DTypeSig false "uncurryPair" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyCon "TestPair")))
(DFunDef false "uncurryPair" ((PTuple (PVar "core") (PVar "mods"))) (EApp (EApp (EVar "TestPair") (EVar "core")) (EVar "mods")))
(DTypeSig false "prepareSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "TestPair"))))))))
(DFunDef false "prepareSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "roots") (PVar "userDecls")) (EBlock (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoExpr (EApp (EVar "uncurryPair") (EApp (EApp (EApp (EVar "elaborateModulesMangled") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (EVar "rootId") (EVar "userDecls"))))))))
(DTypeSig false "driveAll" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool")))))))))))))))
(DFunDef false "driveAll" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls") (PVar "exempt")) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveMulti") (EVar "engines")) (EVar "runtimeDecls")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")) (EVar "exempt")) (EIf (EVar "otherwise") (EMatch (EIf (EVar "exempt") (EVar "None") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "rsrc")) (EVar "csrc"))) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "errText")))) (DoExpr (EVar "False")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveSingle") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "userDecls")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "driveMulti" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))))))))
(DFunDef false "driveMulti" ((PVar "engines") (PVar "runtimeDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls") (PVar "exempt")) (EBlock (DoLet false false (PVar "allExamples") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EVar "allExamples"))) (DoLet false false (PVar "synthResults") (EApp (EVar "buildSynthResults") (EVar "examples"))) (DoLet false false (PVar "synthDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults"))) (DoLet false false (PVar "gated") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prepareMulti") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "exempt")) (EApp (EVar "isNonEmptyL") (EVar "allExamples"))) (EVar "synthDecls"))) (DoExpr (EMatch (EVar "gated") (arm (PTuple (PCon "Some" (PVar "errText")) PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "typecheckGateFail") (EVar "target")) (EVar "errText")))) (DoExpr (EVar "False")))) (arm (PTuple (PCon "None") (PVar "prepared")) () (EIf (EApp (EApp (EApp (EVar "filterMatchedNothing") (EVar "filterOpt")) (EVar "tsrc")) (EVar "userDecls")) (EBlock (DoLet false false PWild (EApp (EVar "filterMatchedNothingNotice") (EVar "target"))) (DoExpr (EVar "False"))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EVar "forcePrepared") (EVar "rsrc")) (EVar "csrc")) (EVar "prepared"))) (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "engines")) (EApp (EVar "DtPair") (EVar "pair"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProps") (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDecls") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk"))))))))))
(DTypeSig false "driveSingle" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Bool"))))))))))))
(DFunDef false "driveSingle" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "userDecls")) (EBlock (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoExpr (EIf (EApp (EApp (EApp (EVar "filterMatchedNothing") (EVar "filterOpt")) (EVar "tsrc")) (EVar "userDecls")) (EBlock (DoLet false false PWild (EApp (EVar "filterMatchedNothingNotice") (EVar "target"))) (DoExpr (EVar "False"))) (EBlock (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "engines")) (EApp (EApp (EApp (EApp (EApp (EVar "DtSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EApp (EVar "buildSynthResults") (EVar "examples")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EApp (EVar "hasTests") (EVar "userDecls"))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EApp (EApp (EVar "prepareSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProps") (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDecls") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk")))) (EVar "doctestsOk"))))))))
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
(DFunDef false "runChosenOn" ((PCon "EngNative") (PVar "_trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runNativeDoctests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")) (EApp (EVar "not") (EVar "exempt"))))))
(DTypeSig false "runChosen" (TyFun (TyCon "DoctestTrees") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult"))))))
(DFunDef false "runChosen" ((PCon "DtPair" (PCon "TestPairErr" (PVar "e"))) (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Err") (EVar "e"))) (EVar "synthResults")) (EVar "examples")))
(DFunDef false "runChosen" ((PCon "DtPair" (PCon "TestPair" (PVar "coreM") (PVar "modsM"))) (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))
(DFunDef false "runChosen" ((PCon "DtSingle" (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "roots") (PVar "userDecls")) (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "allUser") (EBinOp "++" (EVar "userDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults")))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EApp (EVar "funNamesOf") (EVar "allUser"))) (EVar "coreDecls")))) (DoLet false false (PVar "rootId") (EApp (EApp (EVar "singleRootId") (EVar "roots")) (EVar "target"))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateOne") (EVar "runtimeDecls")) (EVar "livePrelude")) (ETuple (EVar "rootId") (EVar "allUser")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalOneWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EListLit)) (ETuple (ELit (LString "__main__")) (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EVar "Ok") (EApp (EApp (EVar "renderExamples") (EVar "env")) (EVar "examples")))) (EVar "synthResults")) (EVar "examples")))))
(DTypeSig false "renderExamples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderExamples" ((PVar "env") (PVar "examples")) (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (ELit (LInt 0))) (EVar "examples")))
(DTypeSig false "renderExamplesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "renderExamplesGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "renderExamplesGo" ((PVar "env") (PVar "i") (PCons (PVar "ex") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "renderOneExample") (EVar "env")) (EVar "i")) (EVar "ex")) (EApp (EApp (EApp (EVar "renderExamplesGo") (EVar "env")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "renderOneExample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderOneExample" ((PVar "env") (PVar "i") (PVar "ex")) (EMatch (EApp (EApp (EVar "lookupBinding") (EApp (EVar "synthName") (EVar "i"))) (EVar "env")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "could not evaluate: ")) (EApp (EVar "exampleInput") (EVar "ex"))))) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))))))
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
(DFunDef false "collectPropLines" ((PCons (PCon "DProp" PWild (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "exprLineLocal") (EVar "body"))) (EApp (EVar "collectPropLines") (EVar "rest"))))
(DFunDef false "collectPropLines" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectPropLines") (EVar "rest")))
(DTypeSig false "exprLineLocal" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprLineLocal" ((PCon "ELoc" (PCon "Loc" PWild (PVar "l") PWild PWild PWild) PWild)) (EVar "l"))
(DFunDef false "exprLineLocal" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "exprLineLocal") (EVar "f")))
(DFunDef false "exprLineLocal" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "exprLineLocal") (EVar "e")))
(DFunDef false "exprLineLocal" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "exprLineLocal") (EVar "e")))
(DFunDef false "exprLineLocal" (PWild) (ELit (LInt 0)))
(DTypeSig false "elaborateModulesMangled" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "elaborateModulesMangled" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EMatch (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules")) (arm (PTuple (PVar "coreE") (PVar "modulesE") PWild PWild PWild) () (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreE") (EVar "modulesE"))))))
(DTypeSig false "runProps" (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runProps" ((PVar "pair") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EVar "True") (EIf (EVar "otherwise") (EMatch (EVar "pair") (arm (PCon "TestPairErr" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "TestPair" (PVar "coreM") (PVar "modsM")) () (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runAllProps") (EVar "cases")) (EVar "filterOpt")) (EVar "target")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EVar "env")) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "elaboratedRootProps" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "elaboratedRootProps" ((PVar "modules") (PVar "userDecls")) (EMatch (EApp (EVar "lastModule") (EVar "modules")) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls"))))
(DTypeSig false "lastModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "lastModule" ((PList)) (EVar "None"))
(DFunDef false "lastModule" ((PList (PTuple PWild (PVar "decls")))) (EApp (EVar "Some") (EVar "decls")))
(DFunDef false "lastModule" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModule") (EVar "rest")))
(DTypeSig false "runTestDecls" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestDecls" ((PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestEngines") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runTestEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestEngines" ((PList (PVar "e")) (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestsOn") (EVar "e")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")))
(DFunDef false "runTestEngines" ((PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestEnginesTagged") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")))
(DTypeSig false "runTestEnginesTagged" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestEnginesTagged" ((PList) PWild PWild PWild PWild PWild PWild) (EVar "True"))
(DFunDef false "runTestEnginesTagged" ((PCons (PVar "e") (PVar "rest")) (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "-- ")) (EApp (EMethodRef "display") (EApp (EVar "engineName") (EVar "e")))) (ELit (LString " --"))))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestsOn") (EVar "e")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))) (DoLet false false (PVar "restOk") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestEnginesTagged") (EVar "rest")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))) (DoExpr (EBinOp "&&" (EVar "ok") (EVar "restOk")))))
(DTypeSig false "runTestsOn" (TyFun (TyCon "Engine") (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))))
(DFunDef false "runTestsOn" ((PCon "EngInterp") (PCon "TestPairErr" (PVar "e")) (PVar "_runtimeDecls") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PVar "_filterOpt")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False"))))
(DFunDef false "runTestsOn" ((PCon "EngInterp") (PCon "TestPair" (PVar "coreM") (PVar "modsM")) (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EVar "gatedReportTests") (EVar "target")) (EBinOp "++" (EBinOp "++" (EVar "runtimeDecls") (EVar "coreM")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modsM")))) (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EApp (EApp (EApp (EApp (EVar "rootTestsOf") (EVar "filterOpt")) (EVar "tsrc")) (EVar "modsM")) (EVar "userDecls"))))
(DFunDef false "runTestsOn" ((PCon "EngNative") (PVar "_pair") (PVar "_runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EVar "runTestDeclsNative") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")))
(DTypeSig false "rootTestsOf" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))))
(DFunDef false "rootTestsOf" ((PVar "filterOpt") (PVar "tsrc") (PVar "modsM") (PVar "userDecls")) (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))))))
(DTypeSig false "runTestDeclsNative" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runTestDeclsNative" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "tests") (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EVar "nativeRawTests") (EVar "tsrc")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running tests in ")) (EVar "target")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EApp (EApp (EApp (EVar "reportNativeTests") (EVar "target")) (EVar "tests")) (EApp (EApp (EApp (EApp (EApp (EVar "runNativeTests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "tests")) (EApp (EVar "not") (EVar "exempt")))))))
(DTypeSig false "nativeRawTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "nativeRawTests" ((PVar "tsrc")) (EApp (EVar "collectTests") (EApp (EVar "parseLocated") (EVar "tsrc"))))
(DTypeSig false "reportNativeTests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "ExResult")) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "reportNativeTests" ((PVar "target") (PVar "tests") (PVar "results")) (EBlock (DoLet false false (PTuple (PVar "passed") (PVar "failed") (PVar "errors")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestLoop") (EVar "target")) (EVar "tests")) (EVar "results")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reportTestSummary") (EVar "target")) (EVar "passed")) (EVar "failed")) (EVar "errors")))))
(DTypeSig false "nativeTestLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "ExResult")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))))))))
(DFunDef false "nativeTestLoop" (PWild (PList) PWild (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EVar "errors")))
(DFunDef false "nativeTestLoop" (PWild (PCons PWild PWild) (PList) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EVar "errors")))
(DFunDef false "nativeTestLoop" ((PVar "target") (PCons (PTuple (PVar "name") (PVar "line") PWild) (PVar "rest")) (PCons (PVar "r") (PVar "rRest")) (PVar "passed") (PVar "failed") (PVar "errors")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "printTestRunning") (EVar "target")) (EVar "line")) (EVar "name"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "printTestVerdict") (EVar "target")) (EVar "line")) (EVar "name")) (EVar "r"))) (DoLet false false (PTuple (PVar "p") (PVar "f") (PVar "e")) (EApp (EApp (EApp (EApp (EVar "tallyTest") (EVar "r")) (EVar "passed")) (EVar "failed")) (EVar "errors"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nativeTestLoop") (EVar "target")) (EVar "rest")) (EVar "rRest")) (EVar "p")) (EVar "f")) (EVar "e")))))
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
(DTypeSig false "gatedReportTests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "gatedReportTests" ((PVar "target") (PVar "corpus") (PVar "env") (PVar "tests")) (EMatch (EApp (EApp (EApp (EVar "uncapableExterns") (EVar "corpus")) (EVar "env")) (EVar "tests")) (arm (PList) () (EApp (EApp (EApp (EVar "reportTests") (EVar "target")) (EVar "env")) (EVar "tests"))) (arm (PVar "names") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "uncapableExternsMsg") (EVar "target")) (EVar "names")))) (DoExpr (EVar "False"))))))
(DTypeSig false "uncapableExternsMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "uncapableExternsMsg" ((PVar "target") (PVar "names")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": `test \"…\"` declarations here reach "))) (EApp (EMethodRef "display") (EApp (EVar "externWord") (EVar "names")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "joinCommas") (EVar "names")))) (ELit (LString ", which `medaka test` does not provide under the interpreter — its capability policy covers the clock, allocation counts and stderr only, so no filesystem, environment, stdin, network or subprocess extern is bound. No test was run. Run these tests natively instead: `medaka test --native "))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "`."))))
(DTypeSig false "externWord" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "externWord" ((PList PWild)) (ELit (LString "the extern")))
(DFunDef false "externWord" (PWild) (ELit (LString "the externs")))
(DTypeSig false "joinCommas" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinCommas" ((PList)) (ELit (LString "")))
(DFunDef false "joinCommas" ((PList (PVar "n"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))))
(DFunDef false "joinCommas" ((PCons (PVar "n") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`, "))) (EApp (EVar "joinCommas") (EVar "rest"))))
(DTypeSig false "reportTests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "reportTests" ((PVar "target") (PVar "env") (PVar "tests")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running tests in ")) (EVar "target")))) (DoLet false false (PTuple (PVar "passed") (PVar "failed") (PVar "errors")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reportTestSummary") (EVar "target")) (EVar "passed")) (EVar "failed")) (EVar "errors")))))
(DTypeSig false "reportTestSummary" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "reportTestSummary" ((PVar "target") (PVar "passed") (PVar "failed") (PVar "errors")) (EBlock (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EVar "passed") (EVar "failed")) (EVar "errors"))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " passed"))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EVar "testFailSuffix") (EVar "failed")) (EVar "errors")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EVar "failed") (ELit (LInt 0))) (EBinOp "==" (EVar "errors") (ELit (LInt 0)))))))
(DTypeSig false "printTestRunning" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "printTestRunning" ((PVar "target") (PVar "line") (PVar "name")) (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  running ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "printTestVerdict" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "ExResult") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "printTestVerdict" ((PVar "target") (PVar "line") (PVar "name") (PVar "result")) (EBlock (DoLet false false (PVar "loc") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString "")))) (DoExpr (EMatch (EVar "result") (arm (PCon "Pass" PWild PWild) () (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ok   ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (arm (PCon "Fail" (PVar "msg") PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg")))))) (arm (PCon "Errored" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg"))))))))))
(DTypeSig false "tallyTest" (TyFun (TyCon "ExResult") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "tallyTest" ((PCon "Pass" PWild PWild) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EBinOp "+" (EVar "passed") (ELit (LInt 1))) (EVar "failed") (EVar "errors")))
(DFunDef false "tallyTest" ((PCon "Fail" PWild PWild PWild) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EBinOp "+" (EVar "failed") (ELit (LInt 1))) (EVar "errors")))
(DFunDef false "tallyTest" ((PCon "Errored" PWild) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EBinOp "+" (EVar "errors") (ELit (LInt 1)))))
(DTypeSig false "runTestLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))))))))
(DFunDef false "runTestLoop" (PWild PWild (PList) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EVar "errors")))
(DFunDef false "runTestLoop" ((PVar "target") (PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest")) (PVar "passed") (PVar "failed") (PVar "errors")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "printTestRunning") (EVar "target")) (EVar "line")) (EVar "name"))) (DoLet false false (PVar "result") (EApp (EApp (EVar "runOneTest") (EVar "env")) (EVar "body"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "printTestVerdict") (EVar "target")) (EVar "line")) (EVar "name")) (EVar "result"))) (DoLet false false (PTuple (PVar "p") (PVar "f") (PVar "e")) (EApp (EApp (EApp (EApp (EVar "tallyTest") (EVar "result")) (EVar "passed")) (EVar "failed")) (EVar "errors"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EVar "p")) (EVar "f")) (EVar "e")))))
(DTypeSig false "testFailSuffix" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "testFailSuffix" ((PVar "failed") (PVar "errors")) (EIf (EBinOp "||" (EBinOp ">" (EVar "failed") (ELit (LInt 0))) (EBinOp ">" (EVar "errors") (ELit (LInt 0)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "errors")))) (ELit (LString " errors)"))) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "runTestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))
(DFunDef false "runTestReport" ((PVar "engines") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "target") (PVar "tsrc") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls")) (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EVar "runtimeSrc"))) (DoLet false false (PVar "coreDecls") (EApp (EVar "desugaredPrelude") (EVar "coreSrc"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportMulti") (EVar "engines")) (EVar "runtimeDecls")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (EVar "userDecls")) (EVar "exempt")) (EMatch (EIf (EVar "exempt") (EVar "None") (EApp (EApp (EApp (EApp (EVar "singleFileTypeErrors") (EVar "target")) (EVar "tsrc")) (EVar "runtimeSrc")) (EVar "coreSrc"))) (arm (PCon "Some" (PVar "errText")) () (ETuple (EApp (EVar "Some") (EVar "errText")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportSingle") (EVar "engines")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "roots")) (EVar "cases")) (EVar "filterOpt")) (EVar "includeTestDecls")) (EVar "userDecls")) (EVar "exempt"))))))))
(DTypeSig false "reportMulti" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool"))))))))))))))))
(DFunDef false "reportMulti" ((PVar "engines") (PVar "runtimeDecls") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls") (PVar "userDecls") (PVar "exempt")) (EBlock (DoLet false false (PVar "allExamples") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EVar "allExamples"))) (DoLet false false (PVar "synthResults") (EApp (EVar "buildSynthResults") (EVar "examples"))) (DoLet false false (PVar "prepared") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "prepareMulti") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "exempt")) (EApp (EVar "isNonEmptyL") (EVar "allExamples"))) (EApp (EVar "buildSynthDecls") (EVar "synthResults")))) (DoExpr (EMatch (EVar "prepared") (arm (PTuple (PCon "Some" (PVar "errText")) PWild) () (ETuple (EApp (EVar "Some") (EVar "errText")) (EListLit) (EListLit) (EListLit) (EVar "False"))) (arm (PTuple (PCon "None") (PVar "prepared")) () (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EVar "forcePrepared") (EVar "rsrc")) (EVar "csrc")) (EVar "prepared"))) (DoExpr (ETuple (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReport") (EVar "engines")) (EApp (EVar "DtPair") (EVar "pair"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReport") (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportTestDecls") (EVar "includeTestDecls")) (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "exempt")))))))))
(DTypeSig false "reportSingle" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyCon "Bool")))))))))))))))
(DFunDef false "reportSingle" ((PVar "engines") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots") (PVar "cases") (PVar "filterOpt") (PVar "includeTestDecls") (PVar "userDecls") (PVar "exempt")) (EBlock (DoLet false false (PVar "examples") (EApp (EApp (EVar "filterExamplesByName") (EVar "filterOpt")) (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc"))))) (DoLet false false (PVar "doctestRuns") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReport") (EVar "engines")) (EApp (EApp (EApp (EApp (EApp (EVar "DtSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EApp (EVar "buildSynthResults") (EVar "examples")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "hasProps") (EVar "userDecls")) (EBinOp "&&" (EVar "includeTestDecls") (EApp (EVar "hasTests") (EVar "userDecls")))) (EBlock (DoLet false false (PVar "pair") (EApp (EApp (EApp (EApp (EApp (EVar "prepareSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "roots")) (EVar "userDecls"))) (DoExpr (ETuple (EVar "None") (EVar "doctestRuns") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propsReport") (EVar "pair")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "cases")) (EVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportTestDecls") (EVar "includeTestDecls")) (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EVar "exempt")))) (ETuple (EVar "None") (EVar "doctestRuns") (EListLit) (EListLit) (EVar "exempt"))))))
(DTypeSig false "reportTestDecls" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))))))))
(DFunDef false "reportTestDecls" ((PCon "False") PWild PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "reportTestDecls" ((PCon "True") (PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReport") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")))
(DTypeSig false "doctestReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))))))))))))
(DFunDef false "doctestReport" ((PVar "engines") (PVar "_trees") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PList) (PVar "_synthResults")) (EApp (EVar "emptyDoctestRuns") (EVar "engines")))
(DFunDef false "doctestReport" ((PVar "engines") (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "engines")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults")))
(DTypeSig false "emptyDoctestRuns" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult")))))
(DFunDef false "emptyDoctestRuns" ((PList)) (EListLit))
(DFunDef false "emptyDoctestRuns" ((PCons (PVar "e") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EVar "RunResult") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))) (EApp (EVar "emptyDoctestRuns") (EVar "rest"))))
(DTypeSig false "doctestReportGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "DoctestTrees") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))))))))))))
(DFunDef false "doctestReportGo" ((PList) PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "doctestReportGo" ((PCons (PVar "e") (PVar "rest")) (PVar "trees") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EBinOp "::" (ETuple (EVar "e") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosenOn") (EVar "e")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "doctestReportGo") (EVar "rest")) (EVar "trees")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))))
(DTypeSig false "propsReport" (TyFun (TyCon "TestPair") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "propsReport" ((PVar "pair") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "cases") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EListLit) (EIf (EVar "otherwise") (EMatch (EVar "pair") (arm (PCon "TestPairErr" PWild) () (EListLit)) (arm (PCon "TestPair" (PVar "coreM") (PVar "modsM")) () (EApp (EApp (EApp (EApp (EApp (EVar "runAllPropsResults") (EVar "cases")) (EVar "filterOpt")) (EApp (EVar "propLineTests") (EVar "tsrc"))) (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EApp (EApp (EVar "elaboratedRootProps") (EVar "modsM")) (EVar "userDecls"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "testDeclsReport" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReport" ((PVar "engines") (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportEngines") (EVar "engines")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "testDeclsReportEngines" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReportEngines" ((PList) PWild PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "testDeclsReportEngines" ((PCons (PVar "e") (PVar "rest")) (PVar "pair") (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "tagWithEngine") (EVar "e")) (EVar "t")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportOn") (EVar "e")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testDeclsReportEngines") (EVar "rest")) (EVar "pair")) (EVar "runtimeDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "filterOpt"))))
(DTypeSig false "tagWithEngine" (TyFun (TyCon "Engine") (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")) (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))
(DFunDef false "tagWithEngine" ((PVar "e") (PTuple (PVar "name") (PVar "line") (PVar "result"))) (ETuple (EVar "e") (EVar "name") (EVar "line") (EVar "result")))
(DTypeSig false "testDeclsReportOn" (TyFun (TyCon "Engine") (TyFun (TyCon "TestPair") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))))))))
(DFunDef false "testDeclsReportOn" ((PCon "EngInterp") (PCon "TestPairErr" PWild) (PVar "_runtimeDecls") (PVar "_target") (PVar "_tsrc") (PVar "_userDecls") (PVar "_filterOpt")) (EListLit))
(DFunDef false "testDeclsReportOn" ((PCon "EngInterp") (PCon "TestPair" (PVar "coreM") (PVar "modsM")) (PVar "runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EApp (EApp (EApp (EApp (EVar "gatedTestsCollect") (EVar "target")) (EBinOp "++" (EBinOp "++" (EVar "runtimeDecls") (EVar "coreM")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modsM")))) (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EVar "coreM")) (EVar "modsM"))) (EApp (EApp (EApp (EApp (EVar "rootTestsOf") (EVar "filterOpt")) (EVar "tsrc")) (EVar "modsM")) (EVar "userDecls"))))
(DFunDef false "testDeclsReportOn" ((PCon "EngNative") (PVar "_pair") (PVar "_runtimeDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "filterOpt")) (EBlock (DoLet false false (PVar "tests") (EApp (EApp (EVar "filterTestsByName") (EVar "filterOpt")) (EApp (EVar "nativeRawTests") (EVar "tsrc")))) (DoLet false false (PVar "exempt") (EApp (EApp (EApp (EVar "typecheckExempt") (EVar "target")) (EVar "userDecls")) (EVar "tsrc"))) (DoExpr (EApp (EApp (EVar "zipTestResults") (EVar "tests")) (EApp (EApp (EApp (EApp (EApp (EVar "runNativeTests") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "tests")) (EApp (EVar "not") (EVar "exempt")))))))
(DTypeSig false "zipTestResults" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "ExResult")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))))
(DFunDef false "zipTestResults" ((PList) PWild) (EListLit))
(DFunDef false "zipTestResults" ((PCons PWild PWild) (PList)) (EListLit))
(DFunDef false "zipTestResults" ((PCons (PTuple (PVar "name") (PVar "line") PWild) (PVar "rest")) (PCons (PVar "r") (PVar "rRest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EVar "r")) (EApp (EApp (EVar "zipTestResults") (EVar "rest")) (EVar "rRest"))))
(DTypeSig false "gatedTestsCollect" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))))
(DFunDef false "gatedTestsCollect" ((PVar "target") (PVar "corpus") (PVar "env") (PVar "tests")) (EMatch (EApp (EApp (EApp (EVar "uncapableExterns") (EVar "corpus")) (EVar "env")) (EVar "tests")) (arm (PList) () (EApp (EApp (EVar "runTestsCollect") (EVar "env")) (EVar "tests"))) (arm (PVar "names") () (EBlock (DoLet false false (PVar "msg") (EApp (EApp (EVar "uncapableExternsMsg") (EVar "target")) (EVar "names"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (ETuple (EApp (EVar "fst3") (EVar "t")) (EApp (EVar "snd3") (EVar "t")) (EApp (EVar "Errored") (EVar "msg"))))) (EVar "tests")))))))
(DTypeSig false "snd3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "b")))
(DFunDef false "snd3" ((PTuple PWild (PVar "b") PWild)) (EVar "b"))
(DTypeSig false "runTestsCollect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "ExResult")))))))
(DFunDef false "runTestsCollect" (PWild (PList)) (EListLit))
(DFunDef false "runTestsCollect" ((PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "line") (EApp (EApp (EVar "runOneTest") (EVar "env")) (EVar "body"))) (EApp (EApp (EVar "runTestsCollect") (EVar "env")) (EVar "rest"))))
(DTypeSig true "testHelpText" (TyCon "String"))
(DFunDef false "testHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka test — Run doctests + property tests\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka test [--native | --engines eval,native] [--json] [--filter <substring>]\n")) (ELit (LString "              [--seed <n>] [--cases <n>] [file.mdk | dir]\n")) (ELit (LString "\n")) (ELit (LString "  --native            run doctests through a compiled native binary\n")) (ELit (LString "                      instead of the interpreter (shorthand for\n")) (ELit (LString "                      --engines native)\n")) (ELit (LString "  --engines e1,e2,...  run the listed engine set (known: eval, native);\n")) (ELit (LString "                      exit code is the AND across engines\n")) (ELit (LString "  --json               emit a {\"file\":...,\"doctests\":...,\"properties\":...,\n")) (ELit (LString "                      \"tests\":...,\"summary\":...} JSON object instead of\n")) (ELit (LString "                      human text (single file.mdk target only; agrees with\n")) (ELit (LString "                      the human report's pass/fail counts on all three\n")) (ELit (LString "                      phases)\n")) (ELit (LString "  --filter <substring> restrict to doctests/`test \"…\"`/`prop \"…\"` whose\n")) (ELit (LString "                      name (or, for a doctest, input expression) contains\n")) (ELit (LString "                      <substring>\n")) (ELit (LString "  --seed <n>           seed the property-test RNG (printed on every prop\n")) (ELit (LString "                      failure so the counterexample is replayable); never\n")) (ELit (LString "                      affects a program under test's own random draws\n")) (ELit (LString "  --cases <n>           run each property with <n> generated cases\n")) (ELit (LString "                      instead of the default 100\n")) (ELit (LString "\n")) (ELit (LString "--native and --engines are mutually exclusive. With neither, the default\n")) (ELit (LString "is the interpreter (eval) alone. A file.mdk or dir target is required.\n")))))
(DTypeSig true "testArgSpec" (TyCon "ArgSpec"))
(DFunDef false "testArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "test"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--native")))) (ELit (LString "shorthand for --engines native"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--engines")))) (ELit (LString "eval,native"))) (ELit (LString "engines to run each example under"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--filter")))) (ELit (LString "SUBSTRING"))) (ELit (LString "run only matching examples"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--seed")))) (ELit (LString "N"))) (ELit (LString "seed the property RNG"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--cases")))) (ELit (LString "N"))) (ELit (LString "property cases per test")))))))
(DTypeSig true "parseTestIntFlag" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "parseTestIntFlag" ((PVar "nm") (PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (EVar "nm")) (EVar "a")) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Some" (PVar "s")) () (EMatch (EApp (EVar "toInt") (EVar "s")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "n")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "nm"))) (ELit (LString " requires an integer value, got '"))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "'")))))))))
(DTypeSig true "parseTestCasesFlag" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "parseTestCasesFlag" ((PVar "a")) (EMatch (EApp (EApp (EVar "parseTestIntFlag") (ELit (LString "--cases"))) (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PCon "None")) () (EApp (EVar "Ok") (EVar "None"))) (arm (PCon "Ok" (PCon "Some" (PVar "n"))) () (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--cases requires a positive integer value, got '")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "'")))) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "n")))))))
(DTypeSig true "parseTestEngines" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Engine")))))
(DFunDef false "parseTestEngines" ((PVar "a")) (EMatch (ETuple (EApp (EApp (EVar "flagValue") (ELit (LString "--engines"))) (EVar "a")) (EApp (EApp (EVar "flag") (ELit (LString "--native"))) (EVar "a"))) (arm (PTuple (PCon "Some" PWild) (PCon "True")) () (EApp (EVar "Err") (ELit (LString "--native and --engines are mutually exclusive; --native is shorthand for --engines native")))) (arm (PTuple (PCon "Some" (PVar "spec")) (PCon "False")) () (EApp (EVar "parseEngineList") (EVar "spec"))) (arm (PTuple (PCon "None") (PCon "True")) () (EApp (EVar "Ok") (EListLit (EVar "EngNative")))) (arm (PTuple (PCon "None") (PCon "False")) () (EApp (EVar "Ok") (EListLit (EVar "EngInterp"))))))
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
(DFunDef false "cliPropJson" ((PVar "p")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EApp (EVar "propResultName") (EVar "p")))) (ETuple (ELit (LString "status")) (EApp (EVar "JString") (EIf (EApp (EVar "propResultPassed") (EVar "p")) (ELit (LString "pass")) (ELit (LString "fail"))))) (ETuple (ELit (LString "detail")) (EApp (EVar "JString") (EApp (EVar "propResultDetail") (EVar "p")))))))
(DTypeSig false "cliTestJson" (TyFun (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult")) (TyCon "Json")))
(DFunDef false "cliTestJson" ((PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "result"))) (EApp (EVar "jObject") (EBinOp "++" (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "engine")) (EApp (EVar "JString") (EApp (EVar "engineName") (EVar "engine"))))) (EApp (EVar "exResultJsonFields") (EVar "result")))))
(DTypeSig false "cliTypeErrorField" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliTypeErrorField" ((PCon "None")) (EListLit))
(DFunDef false "cliTypeErrorField" ((PCon "Some" (PVar "errText"))) (EListLit (ETuple (ELit (LString "typeError")) (EApp (EVar "JString") (EVar "errText")))))
(DTypeSig false "cliTypecheckSkippedField" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json")))))
(DFunDef false "cliTypecheckSkippedField" ((PCon "False")) (EListLit))
(DFunDef false "cliTypecheckSkippedField" ((PCon "True")) (EListLit (ETuple (ELit (LString "typecheckSkipped")) (EApp (EVar "JBool") (EVar "True")))))
(DTypeSig true "cliTestReportJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "RunResult"))) (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Engine") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyFun (TyCon "Bool") (TyCon "Json"))))))))
(DFunDef false "cliTestReportJson" ((PVar "path") (PVar "typeError") (PVar "runs") (PVar "props") (PVar "tests") (PVar "typecheckSkipped")) (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path")))) (EApp (EVar "cliTypeErrorField") (EVar "typeError"))) (EApp (EVar "cliTypecheckSkippedField") (EVar "typecheckSkipped"))) (EListLit (ETuple (ELit (LString "doctests")) (EApp (EVar "cliDoctestsJson") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (ETuple (ELit (LString "properties")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "cliPropJson")) (EVar "props")))) (ETuple (ELit (LString "tests")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "cliTestJson")) (EVar "tests")))) (ETuple (ELit (LString "summary")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "passed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "cliCountPassProps") (EVar "props"))) (EApp (EVar "cliCountPassTests") (EVar "tests"))))) (ETuple (ELit (LString "failed")) (EApp (EVar "JInt") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EApp (EVar "runFailed") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs"))) (EApp (EVar "runErrors") (EApp (EVar "cliPrimaryDoctestRun") (EVar "runs")))) (EApp (EVar "cliCountFailProps") (EVar "props"))) (EApp (EVar "cliCountFailTests") (EVar "tests"))))) (ETuple (ELit (LString "ok")) (EApp (EVar "JBool") (EApp (EApp (EApp (EApp (EVar "cliTestReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")) (EVar "tests")))))))))))
(DTypeSig true "checkTestMdkRoster" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "checkTestMdkRoster" ((PVar "root") (PVar "targets") (PVar "files")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "git"))) (EBinOp "++" (EListLit (ELit (LString "ls-files")) (ELit (LString "--full-name")) (ELit (LString "--"))) (EVar "targets"))) (arm (PCon "Err" PWild) () (EVar "True")) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "tracked") (EApp (EApp (EVar "filterList") (EApp (EVar "endsWith") (ELit (LString "_test.mdk")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitNl") (EVar "out"))))) (DoLet false false (PVar "relFiles") (EApp (EApp (EMethodRef "map") (EApp (EVar "stripRootPrefix") (EVar "root"))) (EVar "files"))) (DoLet false false (PVar "missing") (EApp (EApp (EVar "filterList") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "t")) (EVar "relFiles"))))) (EVar "tracked"))) (DoExpr (EMatch (EVar "missing") (arm (PList) () (EVar "True")) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: git-tracked but not discovered: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "missing")))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))) (arm (PCon "Ok" (PTuple PWild PWild PWild)) () (EVar "True"))))
(DTypeSig false "stripRootPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "stripRootPrefix" ((PVar "root") (PVar "p")) (EBlock (DoLet false false (PVar "prefix") (EBinOp "++" (EVar "root") (ELit (LString "/")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "p")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "p"))) (EVar "p")) (EVar "p")))))
(DTypeSig false "testChildArgs" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "testChildArgs" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "f")) (EBinOp "++" (EListLit (ELit (LString "test")) (EVar "f") (ELit (LString "--engines")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "engineName")) (EVar "engines"))) (ELit (LString "--cases")) (EApp (EVar "intToString") (EVar "cases"))) (EMatch (EVar "filterOpt") (arm (PCon "Some" (PVar "s")) () (EListLit (ELit (LString "--filter")) (EVar "s"))) (arm (PCon "None") () (EListLit)))))
(DTypeSig true "testFilesGo" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool")))))))))))
(DFunDef false "testFilesGo" (PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "testFilesGo" ((PVar "engines") (PVar "rtPath") (PVar "corePath") (PVar "stdlibDir") (PVar "cases") (PVar "filterOpt") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (EApp (EVar "executablePath") (ELit LUnit)))) (DoLet false false (PVar "args") (EApp (EApp (EApp (EApp (EVar "testChildArgs") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "f"))) (DoLet false false (PVar "ok") (EMatch (EApp (EApp (EVar "runCommand") (EVar "medaka")) (EVar "args")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString ": failed to start test runner: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "out"))) (DoLet false false PWild (EApp (EVar "flushStdout") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (EVar "True") (EBlock (DoLet false false PWild (EApp (EVar "ePutStr") (EVar "err"))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString ": DEAD (child exited "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))))) (DoExpr (EVar "False"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EApp (EVar "not") (EVar "ok")))))))
