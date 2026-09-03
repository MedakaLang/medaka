# META
source_lines=371
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/native_doctest.mdk — the NATIVE doctest execution engine
-- (Stage 2 of "make `medaka test` run natively", issue #81).
--
-- `medaka test` runs every doctest under the tree-walking INTERPRETER, so a
-- native-only miscompile is invisible to it — `compiler/tools/test_cmd.mdk`
-- says so in its own comment.  That hole let a SQL expression parser ship
-- 32/32 green while every arithmetic operator in its grammar was broken in the
-- native binary.  This module closes it for doctests: it compiles the module
-- under test — with its doctest bindings appended — to a real native binary,
-- runs it, and reports one rendered actual per example.
--
-- ── the contract ────────────────────────────────────────────────────────────
-- This is an ENGINE behind `doctest.mdk`'s `buildDetailsFrom` seam (Stage 1),
-- exactly like the interpreter arm in `test_cmd.mdk`.  Its whole obligation is
-- "one rendered actual per example, or one whole-file error".  It does NOT
-- decide pass/fail: `buildDetailsFrom` compares actual against expected.
--
-- ⚠️ THAT SPLIT IS LOAD-BEARING.  A compiled program that printed its own
-- `ok`/`FAIL` lines would let a miscompiled `String ==` mark its own homework
-- green — the precise class of bug this engine exists to catch.  The compiled
-- probe therefore only ever PRINTS VALUES; the driver judges them.
--
-- ── one build per FILE, not per example ─────────────────────────────────────
-- `medaka build` is clang-bound (seconds), and `stdlib/string.mdk` alone has 64
-- examples.  So the whole file becomes ONE program: the target's verbatim source
-- ++ every `__dt_i__` synth binding ++ a synthesized `main` that prints each
-- one, separated by sentinel lines the driver splits on.
--
-- VERBATIM source, not a printer round-trip: a round-trip would test the
-- printer as much as the backend, and any formatting divergence would land as a
-- doctest failure in a module that is fine.
--
-- APPENDED INTO THE TARGET'S OWN MODULE, not an importing entry module: doctests
-- routinely exercise module-PRIVATE names (`stdlib/string.mdk`'s do), which an
-- importer cannot see.  This mirrors what the interpreter arm already does with
-- `injectIntoLast` / the `__user__` decl list.
--
-- ⚠️ `synthSrc` (doctest.mdk) is the SINGLE generator of the `__dt_i__` lines,
-- shared with the interpreter arm.  Do not re-derive that text here.  If the two
-- engines generated different synth source they would be testing different
-- programs, and the whole differential is worthless.
--
-- ── the abort rule ──────────────────────────────────────────────────────────
-- If the probe binary dies partway (a panic in example 9 of 64), every example
-- after the last COMPLETE sentinel is reported `Errored` naming the abort — never
-- dropped, never counted as passing.  "This didn't run" must never look like
-- "this passed"; that is the failure mode the whole suite exists to prevent.
--
-- ── NOT wired to any CLI surface ────────────────────────────────────────────
-- Stage 2 delivers the engine only.  `medaka test` still runs the interpreter
-- arm, byte-for-byte unchanged.  Wiring (and the two-engine differential) is
-- Stage 3.  `compiler/entries/native_doctest_probe_main.mdk` drives this module
-- so it is exercised — and typechecked by `typecheck_compiler_source.sh`, which
-- covers `compiler/entries/*` but NOT a `compiler/tools/` module that nothing
-- imports.

import frontend.ast.{Decl, DFunDef, DData, DInterface}
import driver.build_cmd.{
  ppBuildReport,
  makeTempDir,
  cleanupTempDir,
  runBuildNativeRoots,
  envOr,
  defaultMedakaRoot,
}
import driver.loader.{entrySearchRoots}
import support.path.{joinPath, baseOf, dirOf}
import support.util.{joinNl, splitNl}
import tools.probe_transcript.{
  Chunk(..),
  chunksOf,
  endTag,
  firstNonEmptyLine,
  lookupChunk,
  sentinelLine,
}
import tools.doctest.{
  Example,
  RunResult,
  buildDetailsFrom,
  exampleExpected,
  synthName,
  synthSrc,
}

-- ── sentinels ───────────────────────────────────────────────────────────────
-- The transcript format itself — how a sentinel delimits a value and what makes
-- one complete — lives in `tools/probe_transcript.mdk`, shared with the
-- `test "…"` engine.  What is per-engine is the PREFIX, so neither engine can
-- read the other's transcript.

sentinelPrefix : String
sentinelPrefix = "@@__mdk_native_doctest__@@ "

sentinelFor : String -> String
sentinelFor tag = sentinelLine sentinelPrefix tag

-- ── skips that must be LOUD ─────────────────────────────────────────────────
-- Two shapes cannot run natively.  Both return a whole-file error, so every
-- example is reported `Errored` with the reason and the file's summary line
-- reads `0/N passed (0 failed, N errors)`.  A silent skip would read exactly
-- like a pass, which is the one outcome this engine may never produce.
--
-- Ledger: `test/NATIVE-DOCTEST-EXCEPTIONS.txt`.
nativeSkipReason : String -> List Decl -> Option String
nativeSkipReason target userDecls
  | dtProgramIsCore userDecls =
    Some
      "native doctest runner: SKIPPED \{target} — it is the prelude itself, and `medaka build` cannot build stdlib/core.mdk as a program (issue #1334). No example was executed natively."
  | definesMain userDecls =
    Some
      "native doctest runner: SKIPPED \{target} — it already defines a top-level `main`, which the synthesized doctest entry point would collide with. No example was executed natively."
  | otherwise = None

-- The prelude is the unique program declaring BOTH the `Ordering` data type and
-- the `Foldable` interface (same discriminator as `resolve.mdk`'s and
-- `test_cmd.mdk`'s private copies).
dtProgramIsCore : List Decl -> Bool
dtProgramIsCore prog = dtHasOrdering prog && dtHasFoldable prog

dtHasOrdering : List Decl -> Bool
dtHasOrdering [] = False
dtHasOrdering ((DData { dataName = "Ordering" }) :: _) = True
dtHasOrdering (_ :: rest) = dtHasOrdering rest

dtHasFoldable : List Decl -> Bool
dtHasFoldable [] = False
dtHasFoldable ((DInterface { name = "Foldable", ... }) :: _) = True
dtHasFoldable (_ :: rest) = dtHasFoldable rest

definesMain : List Decl -> Bool
definesMain [] = False
definesMain ((DFunDef _ "main" _ _) :: _) = True
definesMain (_ :: rest) = definesMain rest

-- ── entry point ─────────────────────────────────────────────────────────────
-- `target`/`tsrc` are the module under test and its verbatim source;
-- `userDecls` its desugared decls (only for the skip checks); `examples` and
-- `synthResults` come from `doctest.mdk` exactly as the interpreter arm gets
-- them, so both engines judge the same example list with the same indices.
--
-- The build environment (repo root, `medaka`, `CC`) is read here rather than
-- taken as parameters, mirroring `medaka build`'s own `runBuildPlainCmd`.
export
runNativeDoctests : String ->
  String ->
  List Decl ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> RunResult
runNativeDoctests target tsrc userDecls examples synthResults =
  buildDetailsFrom
    (nativeRendered target tsrc userDecls examples synthResults)
    synthResults
    examples

-- The engine's obligation as data: Err = one whole-file failure, Ok = one
-- rendered actual per example (positionally aligned with `examples`).
nativeRendered : String ->
  String ->
  List Decl ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> Result String (List (Result String String))
nativeRendered target tsrc userDecls examples synthResults =
  match nativeSkipReason target userDecls
    Some reason => Err reason
    None => match makeTempDir ()
      Err e =>
        Err "native doctest runner: could not create a scratch directory: \{e}"
      Ok tmpDir =>
        -- `rendered` is bound (and so fully forced — Medaka is strict) BEFORE the
        -- teardown, so the probe binary still exists while it runs.  Same shape as
        -- `build_cmd.mdk`'s `runBuildNative`.
        let rendered = runInTmp target tsrc examples synthResults tmpDir
        let _ = cleanupTempDir tmpDir
        rendered

-- ── the scratch project ─────────────────────────────────────────────────────
-- ⚠️ TRUSTED-ROOT PROBLEM.  A copy of a stdlib module living outside `stdlib/`
-- loses trusted-root status, so its internal-only externs (`arrayGetUnsafe`, …)
-- become hard errors — 7 of them in `stdlib/string.mdk`, measured.
--
-- The fix is a `medaka.toml` written beside the copy.  That is not a trick: it
-- is `loader.mdk`'s OWN documented trust rule (`projectTrustedMods`) — when the
-- entry belongs to a REAL PROJECT (a manifest is found walking up), every module
-- owned by the entry's own search roots is trusted.  The scratch dir genuinely
-- IS a one-module project, so it earns trust by the rule rather than by evading
-- the check.
--
-- Two things were verified on the binary rather than assumed:
--   * `medaka build <copy>` WITHOUT the manifest fails with those 7 errors, and
--     WITH it succeeds — so the manifest is what carries the trust;
--   * the emit path this module actually uses (`runBuildNativeRoots` → the
--     `medaka_emitter` binary) applies no internal-extern guard at all today,
--     so the copy would build either way.  The manifest is therefore belt AND
--     braces: it makes the trust hold by rule, so this engine keeps working if
--     the guard is ever extended to the emit path.
--
-- The alternative — teaching the seam an `--allow-internal`-style bypass — was
-- rejected: it would grant EVERY native doctest run unguarded access to the
-- unsafe array kernels, which is strictly more permission than the module under
-- test has at its real path.
scratchManifest : String
scratchManifest = "[project]\nname = \"medaka_native_doctest\"\n"

-- The copy is named `dt_<basename>` rather than `<basename>`.  A module id
-- collision is otherwise reachable: a copy of `stdlib/string.mdk` in the scratch
-- dir and the real `stdlib/string.mdk` would both claim the module id `string`,
-- and the loader would have to pick one.
scratchEntryName : String -> String
scratchEntryName target = "dt_" ++ baseOf target

runInTmp : String ->
  String ->
  List Example ->
  List (Result String (List Decl)) ->
  String ->
  <IO> Result String (List (Result String String))
runInTmp target tsrc examples synthResults tmpDir =
  let entryPath = joinPath tmpDir (scratchEntryName target)
  let outPath = joinPath tmpDir "dt_probe"
  let _ = writeFile (joinPath tmpDir "medaka.toml") scratchManifest
  match writeFile entryPath (probeSource tsrc examples synthResults)
    Err e => Err "native doctest runner: could not write the probe source: \{e}"
    Ok _ => buildAndRun target entryPath outPath tmpDir examples synthResults

buildAndRun : String ->
  String ->
  String ->
  String ->
  List Example ->
  List (Result String (List Decl)) ->
  <IO> Result String (List (Result String String))
buildAndRun target entryPath outPath tmpDir examples synthResults =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let medaka = envOr "MEDAKA" "medaka"
  let cc = envOr "CC" "clang"
  -- The scratch entry's OWN search roots resolve nothing useful (it sits in a
  -- `mktemp -d`), so the target's real roots are passed as extraRoots — the
  -- exact case Stage 0 added that parameter for.  `compiler`/`stdlib` are
  -- appended by `runBuildNativeRoots` itself.
  let extraRoots = entrySearchRoots (dirOf target)
  match (runBuildNativeRoots
    root
    medaka
    cc
    entryPath
    outPath
    tmpDir
    False
    extraRoots)
    Err rep =>
      Err
        "native doctest runner: could not build \{target} natively\n\{ppBuildReport rep}"
    -- The report's notes are deliberately dropped on SUCCESS even though
    -- MEDAKA_KEEP_IR=1 can still force this runner to keep IR
    -- (effectiveKeepIr ORs the env var in regardless of the False passed
    -- here) — the probe's own stdout is the doctest transcript, and emitter
    -- chatter spliced into it would be read as test output, so any note must
    -- not surface either way.
    Ok _ => match runCommand outPath []
      Err e =>
        Err "native doctest runner: could not run the compiled probe: \{e}"
      Ok (code, out, errOut) =>
        Ok
          (renderAll
            (chunksOf sentinelPrefix (splitNl out))
            (abortNote code errOut)
            0
            examples
            synthResults)

-- ── the probe program ───────────────────────────────────────────────────────
-- target source (verbatim) ++ the `__dt_i__` bindings ++ a synthesized `main`.
--
-- ⚠️ `main` MUST be a zero-arg VALUE.  `medaka run`/the runtime evaluate
-- top-level bindings and never APPLY `main`, so `main () = …` is a silent no-op
-- (exit 0, no output) — which here would present as every example aborting.
--
-- Referencing every `__dt_i__` from `main` is also what keeps `dceFilter` from
-- dropping them: an unreferenced top-level binding is dead code, and a dropped
-- binding is an example that never ran.
probeSource : String ->
  List Example ->
  List (Result String (List Decl)) ->
  String
probeSource tsrc examples synthResults =
  joinNl
    ([tsrc, ""]
      ++ synthLines 0 examples synthResults
      ++ ["", "main ="]
      ++ mainLines 0 examples synthResults
      ++ ["  putStrLn \"\{sentinelFor endTag}\"", ""])

-- One synth binding per example whose synth PARSED.  An example whose synth
-- failed to parse contributes no binding (mirroring `buildSynthDecls`) — its
-- outcome is reported from `synthResults` by `buildDetailsFrom` and never
-- consults the rendered value.
synthLines : Int ->
  List Example ->
  List (Result String (List Decl)) ->
  List String
synthLines _ [] _ = []
synthLines _ (_ :: _) [] = []
synthLines i (ex :: rest) ((Ok _) :: srRest) =
  synthSrc i ex :: synthLines (i + 1) rest srRest
synthLines i (_ :: rest) ((Err _) :: srRest) = synthLines (i + 1) rest srRest

-- Per example: the sentinel, then the value.
--
-- An example WITH an expected block synthesizes `__dt_i__ = debug (expr)`, i.e.
-- a String — printed directly.  A SMOKE example (no expected block) synthesizes
-- the raw expression, whose type is arbitrary and need not be printable, so it
-- is only FORCED and contributes an empty value; `buildDetailsFrom` passes it
-- as long as it evaluated.  (There are currently zero smoke examples in the
-- tree, so this arm is correctness, not machinery.)
mainLines : Int ->
  List Example ->
  List (Result String (List Decl)) ->
  List String
mainLines _ [] _ = []
mainLines _ (_ :: _) [] = []
mainLines i (_ :: rest) ((Err _) :: srRest) = mainLines (i + 1) rest srRest
mainLines i (ex :: rest) ((Ok _) :: srRest) =
  ["  let _ = putStrLn \"\{sentinelFor (intToString i)}\"", valueLine i ex]
    ++ mainLines (i + 1) rest srRest

valueLine : Int -> Example -> String
valueLine i ex = match exampleExpected ex
  Some _ => "  let _ = putStrLn \{synthName i}"
  None => "  let _ = \{synthName i}"

-- ── reading the probe's stdout back ─────────────────────────────────────────

-- ⚠️ THE ABORT RULE.  An example whose chunk is missing, or present but not
-- closed by a following sentinel, is `Errored` NAMING the abort.  It is never
-- dropped and never treated as a pass: a mid-run panic leaving later examples
-- unjudged is exactly the "didn't run looks like passed" failure this engine
-- exists to prevent.  A value that WAS fully printed before the abort is still
-- judged normally — the run is truncated, not invalidated.
abortNote : Int -> String -> String
abortNote code errOut =
  let detail = firstNonEmptyLine (splitNl errOut)
  let suffix = if detail == "" then "" else " — " ++ detail
  "native doctest run ended (probe exit \{intToString code}) before this example was reported\{suffix}"

renderAll : List Chunk ->
  String ->
  Int ->
  List Example ->
  List (Result String (List Decl)) ->
  List (Result String String)
renderAll _ _ _ [] _ = []
renderAll _ _ _ (_ :: _) [] = []
renderAll chunks note i (_ :: rest) (sr :: srRest) =
  renderOne chunks note i sr :: renderAll chunks note (i + 1) rest srRest

-- The `Err _` synth arm's payload is never read: `buildDetailsFrom`'s
-- `oneResultOk` reports that example's own parse error and ignores the rendered
-- entry.  It exists to keep the list positionally aligned with `examples`.
renderOne : List Chunk ->
  String ->
  Int ->
  Result String (List Decl) ->
  Result String String
renderOne _ _ _ (Err _) = Err "example did not parse"
renderOne chunks note i (Ok _) = match lookupChunk (intToString i) chunks
  Some (Chunk _ ls True) => Ok (joinNl ls)
  Some (Chunk _ _ False) => Err note
  None => Err note
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DFunDef" false) (mem "DData" false) (mem "DInterface" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "ppBuildReport" false) (mem "makeTempDir" false) (mem "cleanupTempDir" false) (mem "runBuildNativeRoots" false) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false) (mem "baseOf" false) (mem "dirOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "splitNl" false))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "Chunk" true) (mem "chunksOf" false) (mem "endTag" false) (mem "firstNonEmptyLine" false) (mem "lookupChunk" false) (mem "sentinelLine" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "RunResult" false) (mem "buildDetailsFrom" false) (mem "exampleExpected" false) (mem "synthName" false) (mem "synthSrc" false))))
(DTypeSig false "sentinelPrefix" (TyCon "String"))
(DFunDef false "sentinelPrefix" () (ELit (LString "@@__mdk_native_doctest__@@ ")))
(DTypeSig false "sentinelFor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sentinelFor" ((PVar "tag")) (EApp (EApp (EVar "sentinelLine") (EVar "sentinelPrefix")) (EVar "tag")))
(DTypeSig false "nativeSkipReason" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "nativeSkipReason" ((PVar "target") (PVar "userDecls")) (EIf (EApp (EVar "dtProgramIsCore") (EVar "userDecls")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: SKIPPED ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString " — it is the prelude itself, and `medaka build` cannot build stdlib/core.mdk as a program (issue #1334). No example was executed natively.")))) (EIf (EApp (EVar "definesMain") (EVar "userDecls")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: SKIPPED ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString " — it already defines a top-level `main`, which the synthesized doctest entry point would collide with. No example was executed natively.")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "dtProgramIsCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "dtProgramIsCore" ((PVar "prog")) (EBinOp "&&" (EApp (EVar "dtHasOrdering") (EVar "prog")) (EApp (EVar "dtHasFoldable") (EVar "prog"))))
(DTypeSig false "dtHasOrdering" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "dtHasOrdering" ((PList)) (EVar "False"))
(DFunDef false "dtHasOrdering" ((PCons (PRec "DData" ((rf "dataName" (PLit (LString "Ordering")))) false) PWild)) (EVar "True"))
(DFunDef false "dtHasOrdering" ((PCons PWild (PVar "rest"))) (EApp (EVar "dtHasOrdering") (EVar "rest")))
(DTypeSig false "dtHasFoldable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "dtHasFoldable" ((PList)) (EVar "False"))
(DFunDef false "dtHasFoldable" ((PCons (PRec "DInterface" ((rf "name" (PLit (LString "Foldable")))) true) PWild)) (EVar "True"))
(DFunDef false "dtHasFoldable" ((PCons PWild (PVar "rest"))) (EApp (EVar "dtHasFoldable") (EVar "rest")))
(DTypeSig false "definesMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "definesMain" ((PList)) (EVar "False"))
(DFunDef false "definesMain" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) PWild PWild) PWild)) (EVar "True"))
(DFunDef false "definesMain" ((PCons PWild (PVar "rest"))) (EApp (EVar "definesMain") (EVar "rest")))
(DTypeSig true "runNativeDoctests" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult"))))))))
(DFunDef false "runNativeDoctests" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EApp (EApp (EApp (EApp (EVar "nativeRendered") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (EVar "synthResults")) (EVar "examples")))
(DTypeSig false "nativeRendered" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))))))
(DFunDef false "nativeRendered" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EMatch (EApp (EApp (EVar "nativeSkipReason") (EVar "target")) (EVar "userDecls")) (arm (PCon "Some" (PVar "reason")) () (EApp (EVar "Err") (EVar "reason"))) (arm (PCon "None") () (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: could not create a scratch directory: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "rendered") (EApp (EApp (EApp (EApp (EApp (EVar "runInTmp") (EVar "target")) (EVar "tsrc")) (EVar "examples")) (EVar "synthResults")) (EVar "tmpDir"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "rendered"))))))))
(DTypeSig false "scratchManifest" (TyCon "String"))
(DFunDef false "scratchManifest" () (ELit (LString "[project]\nname = \"medaka_native_doctest\"\n")))
(DTypeSig false "scratchEntryName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "scratchEntryName" ((PVar "target")) (EBinOp "++" (ELit (LString "dt_")) (EApp (EVar "baseOf") (EVar "target"))))
(DTypeSig false "runInTmp" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))))))
(DFunDef false "runInTmp" ((PVar "target") (PVar "tsrc") (PVar "examples") (PVar "synthResults") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "entryPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (EApp (EVar "scratchEntryName") (EVar "target")))) (DoLet false false (PVar "outPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "dt_probe")))) (DoLet false false PWild (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "medaka.toml")))) (EVar "scratchManifest"))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "entryPath")) (EApp (EApp (EApp (EVar "probeSource") (EVar "tsrc")) (EVar "examples")) (EVar "synthResults"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: could not write the probe source: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildAndRun") (EVar "target")) (EVar "entryPath")) (EVar "outPath")) (EVar "tmpDir")) (EVar "examples")) (EVar "synthResults")))))))
(DTypeSig false "buildAndRun" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))))))
(DFunDef false "buildAndRun" ((PVar "target") (PVar "entryPath") (PVar "outPath") (PVar "tmpDir") (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "extraRoots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeRoots") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "entryPath")) (EVar "outPath")) (EVar "tmpDir")) (EVar "False")) (EVar "extraRoots")) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: could not build ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString " natively\n"))) (EApp (EVar "display") (EApp (EVar "ppBuildReport") (EVar "rep")))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (EVar "outPath")) (EListLit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: could not run the compiled probe: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "errOut"))) () (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "renderAll") (EApp (EApp (EVar "chunksOf") (EVar "sentinelPrefix")) (EApp (EVar "splitNl") (EVar "out")))) (EApp (EApp (EVar "abortNote") (EVar "code")) (EVar "errOut"))) (ELit (LInt 0))) (EVar "examples")) (EVar "synthResults"))))))))))
(DTypeSig false "probeSource" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "probeSource" ((PVar "tsrc") (PVar "examples") (PVar "synthResults")) (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "tsrc") (ELit (LString ""))) (EApp (EApp (EApp (EVar "synthLines") (ELit (LInt 0))) (EVar "examples")) (EVar "synthResults"))) (EListLit (ELit (LString "")) (ELit (LString "main =")))) (EApp (EApp (EApp (EVar "mainLines") (ELit (LInt 0))) (EVar "examples")) (EVar "synthResults"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  putStrLn \"")) (EApp (EVar "display") (EApp (EVar "sentinelFor") (EVar "endTag")))) (ELit (LString "\""))) (ELit (LString ""))))))
(DTypeSig false "synthLines" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "synthLines" (PWild (PList) PWild) (EListLit))
(DFunDef false "synthLines" (PWild (PCons PWild PWild) (PList)) (EListLit))
(DFunDef false "synthLines" ((PVar "i") (PCons (PVar "ex") (PVar "rest")) (PCons (PCon "Ok" PWild) (PVar "srRest"))) (EBinOp "::" (EApp (EApp (EVar "synthSrc") (EVar "i")) (EVar "ex")) (EApp (EApp (EApp (EVar "synthLines") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "srRest"))))
(DFunDef false "synthLines" ((PVar "i") (PCons PWild (PVar "rest")) (PCons (PCon "Err" PWild) (PVar "srRest"))) (EApp (EApp (EApp (EVar "synthLines") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "srRest")))
(DTypeSig false "mainLines" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "mainLines" (PWild (PList) PWild) (EListLit))
(DFunDef false "mainLines" (PWild (PCons PWild PWild) (PList)) (EListLit))
(DFunDef false "mainLines" ((PVar "i") (PCons PWild (PVar "rest")) (PCons (PCon "Err" PWild) (PVar "srRest"))) (EApp (EApp (EApp (EVar "mainLines") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "srRest")))
(DFunDef false "mainLines" ((PVar "i") (PCons (PVar "ex") (PVar "rest")) (PCons (PCon "Ok" PWild) (PVar "srRest"))) (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = putStrLn \"")) (EApp (EVar "display") (EApp (EVar "sentinelFor") (EApp (EVar "intToString") (EVar "i"))))) (ELit (LString "\""))) (EApp (EApp (EVar "valueLine") (EVar "i")) (EVar "ex"))) (EApp (EApp (EApp (EVar "mainLines") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "srRest"))))
(DTypeSig false "valueLine" (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyCon "String"))))
(DFunDef false "valueLine" ((PVar "i") (PVar "ex")) (EMatch (EApp (EVar "exampleExpected") (EVar "ex")) (arm (PCon "Some" PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = putStrLn ")) (EApp (EVar "display") (EApp (EVar "synthName") (EVar "i")))) (ELit (LString "")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "synthName") (EVar "i")))) (ELit (LString ""))))))
(DTypeSig false "abortNote" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "abortNote" ((PVar "code") (PVar "errOut")) (EBlock (DoLet false false (PVar "detail") (EApp (EVar "firstNonEmptyLine") (EApp (EVar "splitNl") (EVar "errOut")))) (DoLet false false (PVar "suffix") (EIf (EBinOp "==" (EVar "detail") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (ELit (LString " — ")) (EVar "detail")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest run ended (probe exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ") before this example was reported"))) (EApp (EVar "display") (EVar "suffix"))) (ELit (LString ""))))))
(DTypeSig false "renderAll" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))))
(DFunDef false "renderAll" (PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "renderAll" (PWild PWild PWild (PCons PWild PWild) (PList)) (EListLit))
(DFunDef false "renderAll" ((PVar "chunks") (PVar "note") (PVar "i") (PCons PWild (PVar "rest")) (PCons (PVar "sr") (PVar "srRest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "renderOne") (EVar "chunks")) (EVar "note")) (EVar "i")) (EVar "sr")) (EApp (EApp (EApp (EApp (EApp (EVar "renderAll") (EVar "chunks")) (EVar "note")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "srRest"))))
(DTypeSig false "renderOne" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderOne" (PWild PWild PWild (PCon "Err" PWild)) (EApp (EVar "Err") (ELit (LString "example did not parse"))))
(DFunDef false "renderOne" ((PVar "chunks") (PVar "note") (PVar "i") (PCon "Ok" PWild)) (EMatch (EApp (EApp (EVar "lookupChunk") (EApp (EVar "intToString") (EVar "i"))) (EVar "chunks")) (arm (PCon "Some" (PCon "Chunk" PWild (PVar "ls") (PCon "True"))) () (EApp (EVar "Ok") (EApp (EVar "joinNl") (EVar "ls")))) (arm (PCon "Some" (PCon "Chunk" PWild PWild (PCon "False"))) () (EApp (EVar "Err") (EVar "note"))) (arm (PCon "None") () (EApp (EVar "Err") (EVar "note")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DFunDef" false) (mem "DData" false) (mem "DInterface" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "ppBuildReport" false) (mem "makeTempDir" false) (mem "cleanupTempDir" false) (mem "runBuildNativeRoots" false) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false) (mem "baseOf" false) (mem "dirOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "splitNl" false))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "Chunk" true) (mem "chunksOf" false) (mem "endTag" false) (mem "firstNonEmptyLine" false) (mem "lookupChunk" false) (mem "sentinelLine" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "RunResult" false) (mem "buildDetailsFrom" false) (mem "exampleExpected" false) (mem "synthName" false) (mem "synthSrc" false))))
(DTypeSig false "sentinelPrefix" (TyCon "String"))
(DFunDef false "sentinelPrefix" () (ELit (LString "@@__mdk_native_doctest__@@ ")))
(DTypeSig false "sentinelFor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sentinelFor" ((PVar "tag")) (EApp (EApp (EVar "sentinelLine") (EVar "sentinelPrefix")) (EVar "tag")))
(DTypeSig false "nativeSkipReason" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "nativeSkipReason" ((PVar "target") (PVar "userDecls")) (EIf (EApp (EVar "dtProgramIsCore") (EVar "userDecls")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: SKIPPED ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString " — it is the prelude itself, and `medaka build` cannot build stdlib/core.mdk as a program (issue #1334). No example was executed natively.")))) (EIf (EApp (EVar "definesMain") (EVar "userDecls")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: SKIPPED ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString " — it already defines a top-level `main`, which the synthesized doctest entry point would collide with. No example was executed natively.")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "dtProgramIsCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "dtProgramIsCore" ((PVar "prog")) (EBinOp "&&" (EApp (EVar "dtHasOrdering") (EVar "prog")) (EApp (EVar "dtHasFoldable") (EVar "prog"))))
(DTypeSig false "dtHasOrdering" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "dtHasOrdering" ((PList)) (EVar "False"))
(DFunDef false "dtHasOrdering" ((PCons (PRec "DData" ((rf "dataName" (PLit (LString "Ordering")))) false) PWild)) (EVar "True"))
(DFunDef false "dtHasOrdering" ((PCons PWild (PVar "rest"))) (EApp (EVar "dtHasOrdering") (EVar "rest")))
(DTypeSig false "dtHasFoldable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "dtHasFoldable" ((PList)) (EVar "False"))
(DFunDef false "dtHasFoldable" ((PCons (PRec "DInterface" ((rf "name" (PLit (LString "Foldable")))) true) PWild)) (EVar "True"))
(DFunDef false "dtHasFoldable" ((PCons PWild (PVar "rest"))) (EApp (EVar "dtHasFoldable") (EVar "rest")))
(DTypeSig false "definesMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "definesMain" ((PList)) (EVar "False"))
(DFunDef false "definesMain" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) PWild PWild) PWild)) (EVar "True"))
(DFunDef false "definesMain" ((PCons PWild (PVar "rest"))) (EApp (EVar "definesMain") (EVar "rest")))
(DTypeSig true "runNativeDoctests" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult"))))))))
(DFunDef false "runNativeDoctests" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EApp (EApp (EApp (EVar "buildDetailsFrom") (EApp (EApp (EApp (EApp (EApp (EVar "nativeRendered") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "examples")) (EVar "synthResults"))) (EVar "synthResults")) (EVar "examples")))
(DTypeSig false "nativeRendered" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))))))
(DFunDef false "nativeRendered" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "examples") (PVar "synthResults")) (EMatch (EApp (EApp (EVar "nativeSkipReason") (EVar "target")) (EVar "userDecls")) (arm (PCon "Some" (PVar "reason")) () (EApp (EVar "Err") (EVar "reason"))) (arm (PCon "None") () (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: could not create a scratch directory: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "rendered") (EApp (EApp (EApp (EApp (EApp (EVar "runInTmp") (EVar "target")) (EVar "tsrc")) (EVar "examples")) (EVar "synthResults")) (EVar "tmpDir"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "rendered"))))))))
(DTypeSig false "scratchManifest" (TyCon "String"))
(DFunDef false "scratchManifest" () (ELit (LString "[project]\nname = \"medaka_native_doctest\"\n")))
(DTypeSig false "scratchEntryName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "scratchEntryName" ((PVar "target")) (EBinOp "++" (ELit (LString "dt_")) (EApp (EVar "baseOf") (EVar "target"))))
(DTypeSig false "runInTmp" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))))))
(DFunDef false "runInTmp" ((PVar "target") (PVar "tsrc") (PVar "examples") (PVar "synthResults") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "entryPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (EApp (EVar "scratchEntryName") (EVar "target")))) (DoLet false false (PVar "outPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "dt_probe")))) (DoLet false false PWild (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "medaka.toml")))) (EVar "scratchManifest"))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "entryPath")) (EApp (EApp (EApp (EVar "probeSource") (EVar "tsrc")) (EVar "examples")) (EVar "synthResults"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: could not write the probe source: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildAndRun") (EVar "target")) (EVar "entryPath")) (EVar "outPath")) (EVar "tmpDir")) (EVar "examples")) (EVar "synthResults")))))))
(DTypeSig false "buildAndRun" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))))))
(DFunDef false "buildAndRun" ((PVar "target") (PVar "entryPath") (PVar "outPath") (PVar "tmpDir") (PVar "examples") (PVar "synthResults")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "extraRoots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeRoots") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "entryPath")) (EVar "outPath")) (EVar "tmpDir")) (EVar "False")) (EVar "extraRoots")) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: could not build ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString " natively\n"))) (EApp (EMethodRef "display") (EApp (EVar "ppBuildReport") (EVar "rep")))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (EVar "outPath")) (EListLit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest runner: could not run the compiled probe: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "errOut"))) () (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "renderAll") (EApp (EApp (EVar "chunksOf") (EVar "sentinelPrefix")) (EApp (EVar "splitNl") (EVar "out")))) (EApp (EApp (EVar "abortNote") (EVar "code")) (EVar "errOut"))) (ELit (LInt 0))) (EVar "examples")) (EVar "synthResults"))))))))))
(DTypeSig false "probeSource" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "probeSource" ((PVar "tsrc") (PVar "examples") (PVar "synthResults")) (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "tsrc") (ELit (LString ""))) (EApp (EApp (EApp (EVar "synthLines") (ELit (LInt 0))) (EVar "examples")) (EVar "synthResults"))) (EListLit (ELit (LString "")) (ELit (LString "main =")))) (EApp (EApp (EApp (EVar "mainLines") (ELit (LInt 0))) (EVar "examples")) (EVar "synthResults"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  putStrLn \"")) (EApp (EMethodRef "display") (EApp (EVar "sentinelFor") (EVar "endTag")))) (ELit (LString "\""))) (ELit (LString ""))))))
(DTypeSig false "synthLines" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "synthLines" (PWild (PList) PWild) (EListLit))
(DFunDef false "synthLines" (PWild (PCons PWild PWild) (PList)) (EListLit))
(DFunDef false "synthLines" ((PVar "i") (PCons (PVar "ex") (PVar "rest")) (PCons (PCon "Ok" PWild) (PVar "srRest"))) (EBinOp "::" (EApp (EApp (EVar "synthSrc") (EVar "i")) (EVar "ex")) (EApp (EApp (EApp (EVar "synthLines") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "srRest"))))
(DFunDef false "synthLines" ((PVar "i") (PCons PWild (PVar "rest")) (PCons (PCon "Err" PWild) (PVar "srRest"))) (EApp (EApp (EApp (EVar "synthLines") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "srRest")))
(DTypeSig false "mainLines" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "mainLines" (PWild (PList) PWild) (EListLit))
(DFunDef false "mainLines" (PWild (PCons PWild PWild) (PList)) (EListLit))
(DFunDef false "mainLines" ((PVar "i") (PCons PWild (PVar "rest")) (PCons (PCon "Err" PWild) (PVar "srRest"))) (EApp (EApp (EApp (EVar "mainLines") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "srRest")))
(DFunDef false "mainLines" ((PVar "i") (PCons (PVar "ex") (PVar "rest")) (PCons (PCon "Ok" PWild) (PVar "srRest"))) (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = putStrLn \"")) (EApp (EMethodRef "display") (EApp (EVar "sentinelFor") (EApp (EVar "intToString") (EVar "i"))))) (ELit (LString "\""))) (EApp (EApp (EVar "valueLine") (EVar "i")) (EVar "ex"))) (EApp (EApp (EApp (EVar "mainLines") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "srRest"))))
(DTypeSig false "valueLine" (TyFun (TyCon "Int") (TyFun (TyCon "Example") (TyCon "String"))))
(DFunDef false "valueLine" ((PVar "i") (PVar "ex")) (EMatch (EApp (EVar "exampleExpected") (EVar "ex")) (arm (PCon "Some" PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = putStrLn ")) (EApp (EMethodRef "display") (EApp (EVar "synthName") (EVar "i")))) (ELit (LString "")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "synthName") (EVar "i")))) (ELit (LString ""))))))
(DTypeSig false "abortNote" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "abortNote" ((PVar "code") (PVar "errOut")) (EBlock (DoLet false false (PVar "detail") (EApp (EVar "firstNonEmptyLine") (EApp (EVar "splitNl") (EVar "errOut")))) (DoLet false false (PVar "suffix") (EIf (EBinOp "==" (EVar "detail") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (ELit (LString " — ")) (EVar "detail")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native doctest run ended (probe exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ") before this example was reported"))) (EApp (EMethodRef "display") (EVar "suffix"))) (ELit (LString ""))))))
(DTypeSig false "renderAll" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))))
(DFunDef false "renderAll" (PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "renderAll" (PWild PWild PWild (PCons PWild PWild) (PList)) (EListLit))
(DFunDef false "renderAll" ((PVar "chunks") (PVar "note") (PVar "i") (PCons PWild (PVar "rest")) (PCons (PVar "sr") (PVar "srRest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "renderOne") (EVar "chunks")) (EVar "note")) (EVar "i")) (EVar "sr")) (EApp (EApp (EApp (EApp (EApp (EVar "renderAll") (EVar "chunks")) (EVar "note")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "srRest"))))
(DTypeSig false "renderOne" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "renderOne" (PWild PWild PWild (PCon "Err" PWild)) (EApp (EVar "Err") (ELit (LString "example did not parse"))))
(DFunDef false "renderOne" ((PVar "chunks") (PVar "note") (PVar "i") (PCon "Ok" PWild)) (EMatch (EApp (EApp (EVar "lookupChunk") (EApp (EVar "intToString") (EVar "i"))) (EVar "chunks")) (arm (PCon "Some" (PCon "Chunk" PWild (PVar "ls") (PCon "True"))) () (EApp (EVar "Ok") (EApp (EVar "joinNl") (EVar "ls")))) (arm (PCon "Some" (PCon "Chunk" PWild PWild (PCon "False"))) () (EApp (EVar "Err") (EVar "note"))) (arm (PCon "None") () (EApp (EVar "Err") (EVar "note")))))
