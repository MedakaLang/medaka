# META
source_lines=391
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/native_test_decls.mdk — the NATIVE execution engine for
-- `test "…"` declarations (`medaka test --native`, issue #2588 / epic #2600).
--
-- ⚠️ NOT named `native_test.mdk`.  A compiler path ending in `_test.mdk` is a
-- TEST SIBLING by convention ([P-TEST-SIBLING]) and three computations subtract
-- that suffix: both source fingerprints in `test/build_native_medaka.sh`, their
-- mirror `liveSourceFingerprint` in `compiler/driver/medaka_cli.mdk`, and the
-- `compiler` family of `test/diff_compiler_snapshot_frontend.sh`.  Under the
-- shorter name this production module would neither trigger an emitter rebuild
-- nor mark a binary stale when edited, and would owe no blessed snapshot —
-- MEASURED: `find compiler -name '*.mdk' -not -name '*_test.mdk'` excludes it.
--
-- `compiler/tools/native_doctest.mdk` does this for DOCTESTS.  This module is
-- its sibling for the `test "…"` phase: it is the TEMPLATE, not shared code.
-- The two arms differ in what they have to synthesize — a doctest already owns
-- a source expression (`synthSrc`), a `test "…"` decl owns an `Expr` — so the
-- probe programs are generated differently even though the build/run/abort
-- machinery has the same shape.
--
-- ── the contract ────────────────────────────────────────────────────────────
-- The probe only ever PRINTS.  It prints, per test, the `Expectation`'s
-- constructor tag and its rendered operands, each between sentinel lines; the
-- DRIVER decides pass/fail.  A compiled program that printed its own `ok`/`FAIL`
-- lines would let a miscompiled `String ==` mark its own homework green — the
-- precise class of bug a native arm exists to catch.
--
-- ── one build per FILE, not per test ────────────────────────────────────────
-- `medaka build` is clang-bound (seconds), so the whole file becomes ONE
-- program: the target's verbatim source ++ one `__ts_i__` binding per test ++
-- one `__tse_i__` printer per test ++ a synthesized `main`.
--
-- VERBATIM source for the module, printed source for the BODIES: a `test "…"`
-- decl's body is only reachable as an `Expr` (a `DTest` body does not emit —
-- `compiler/ir/dce.mdk`), so it is re-rendered through `printer.declToString`
-- as an ordinary binding.  The module around it is never round-tripped.
--
-- ── the abort rule ──────────────────────────────────────────────────────────
-- If the probe dies partway (a `panic` in test 9 of 64), every test whose
-- chunks are missing or unterminated is reported `Errored` naming the abort —
-- never dropped, never counted as passing.  "This didn't run" must never look
-- like "this passed".

import frontend.ast.{Decl, DFunDef, Expr, PWild}
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
import support.util.{joinNl, splitNl, anyList}
import tools.doctest.{ExResult(..)}
import tools.probe_transcript.{
  Chunk(..),
  chunksOf,
  decodeValue,
  endTag,
  firstNonEmptyLine,
  lookupChunk,
  sentinelLine,
  tagsInOrder,
  valuePrintExpr,
}
import tools.printer.{declToString}

-- ── sentinels ───────────────────────────────────────────────────────────────
-- The transcript format itself — how a sentinel delimits a value and what makes
-- one complete — lives in `tools/probe_transcript.mdk`, shared with the doctest
-- engine.  What is per-engine is the PREFIX (so neither engine can read the
-- other's transcript) and the tag vocabulary below.

sentinelPrefix : String
sentinelPrefix = "@@__mdk_native_test__@@ "

sentinelFor : String -> String
sentinelFor tag = sentinelLine sentinelPrefix tag

-- Chunk tags, per test index: `<i>.start` is printed BEFORE the body is forced,
-- so a body that panics leaves its own start chunk unterminated and is named
-- rather than blamed on its predecessor.  `<i>.tag`/`.msg`/`.exp`/`.act` carry
-- the `Expectation`'s constructor and its three rendered fields.
startTag : Int -> String
startTag i = "\{intToString i}.start"

fieldTag : Int -> String -> String
fieldTag i f = "\{intToString i}.\{f}"

-- Every tag this engine's probe prints, in the order it prints them — the
-- sequence `tagsInOrder` holds the transcript to.
expectedTags : Int -> List (String, Int, Expr) -> List String
expectedTags _ [] = [endTag]
expectedTags i (_ :: rest) =
  [
      startTag i,
      fieldTag i "tag",
      fieldTag i "msg",
      fieldTag i "exp",
      fieldTag i "act",
    ]
    ++ expectedTags (i + 1) rest

-- ── skips that must be LOUD ─────────────────────────────────────────────────
-- A target that already defines `main` cannot host the synthesized entry point.
-- Every other shape that cannot build reports the BUILD's own error, which is
-- loud by construction.  A silent skip would read exactly like a pass, which is
-- the one outcome this engine may never produce.
nativeTestSkipReason : String -> List Decl -> Option String
nativeTestSkipReason target userDecls
  | definesMain userDecls =
    Some
      "native test runner: SKIPPED \{target} — it already defines a top-level `main`, which the synthesized test entry point would collide with. No test was executed natively."
  | otherwise = None

definesMain : List Decl -> Bool
definesMain decls = anyList isMainDef decls

isMainDef : Decl -> Bool
isMainDef (DFunDef _ "main" _ _) = True
isMainDef _ = False

-- ── entry point ─────────────────────────────────────────────────────────────
-- `tests` is `(name, line, RAW body)` in the same order and after the same
-- `--filter` the interpreter arm applies, so index `i` here is the same test
-- the driver names at index `i`.  The result is one `ExResult` per test,
-- positionally aligned.
export
runNativeTests : String ->
  String ->
  List Decl ->
  List (String, Int, Expr) ->
  <IO> List ExResult
runNativeTests target tsrc userDecls tests =
  match nativeRendered target tsrc userDecls tests
    Err reason => map (_ => Errored reason) tests
    Ok results => results

nativeRendered : String ->
  String ->
  List Decl ->
  List (String, Int, Expr) ->
  <IO> Result String (List ExResult)
nativeRendered target tsrc userDecls tests =
  match nativeTestSkipReason target userDecls
    Some reason => Err reason
    None => match makeTempDir ()
      Err e =>
        Err "native test runner: could not create a scratch directory: \{e}"
      Ok tmpDir =>
        -- `results` is bound (and so fully forced — Medaka is strict) BEFORE the
        -- teardown, so the probe binary still exists while it runs.
        let results = runInTmp target tsrc tests tmpDir
        let _ = cleanupTempDir tmpDir
        results

-- ── the scratch project ─────────────────────────────────────────────────────
-- The manifest is what carries trusted-root status to the copy, so a module
-- whose tests use internal-only externs still builds; `native_doctest.mdk`
-- documents the measurement behind that rule.
scratchManifest : String
scratchManifest = "[project]\nname = \"medaka_native_test\"\n"

-- Named `ts_<basename>` so the copy cannot claim the same module id as the
-- original (which the loader would then have to choose between).
scratchEntryName : String -> String
scratchEntryName target = "ts_" ++ baseOf target

runInTmp : String ->
  String ->
  List (String, Int, Expr) ->
  String ->
  <IO> Result String (List ExResult)
runInTmp target tsrc tests tmpDir =
  let entryPath = joinPath tmpDir (scratchEntryName target)
  let outPath = joinPath tmpDir "ts_probe"
  let _ = writeFile (joinPath tmpDir "medaka.toml") scratchManifest
  match writeFile entryPath (probeSource tsrc tests)
    Err e => Err "native test runner: could not write the probe source: \{e}"
    Ok _ => buildAndRun target entryPath outPath tmpDir tests

buildAndRun : String ->
  String ->
  String ->
  String ->
  List (String, Int, Expr) ->
  <IO> Result String (List ExResult)
buildAndRun target entryPath outPath tmpDir tests =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let medaka = envOr "MEDAKA" "medaka"
  let cc = envOr "CC" "clang"
  -- The scratch entry sits in a `mktemp -d`, so its own search roots resolve
  -- nothing; the target's real roots are passed as extraRoots.
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
        "native test runner: could not build \{target} natively\n\{ppBuildReport rep}"
    Ok _ => match runCommand outPath []
      Err e => Err "native test runner: could not run the compiled probe: \{e}"
      Ok (code, out, errOut) =>
        let chunks = chunksOf sentinelPrefix (splitNl out)
        if tagsInOrder (expectedTags 0 tests) chunks then
          Ok (renderAll chunks (abortNote code errOut) 0 tests)
        else
          Err forgedTranscript

-- ── the probe program ───────────────────────────────────────────────────────
-- THE PROBE MAY NOT NAME `Pass` OR `Fail`.  The target's source is spliced
-- into THIS module's scope, so a target that declares constructors of its own
-- spelled `Pass`/`Fail` (a real shape — `test/compiler_test_fixtures/
-- ctor_collision_test_seam/verdict.mdk` declares exactly that, pinning the
-- analogous eval-engine exemption) wins the bare name over anything this file
-- imports, and the printers below stop being about `Expectation` at all.  So
-- `test` is imported UNDER AN ALIAS and the result is read through the
-- accessors in `stdlib/test.mdk`, which resolve those constructors in the one
-- module where they are unambiguous.  An alias-qualified name cannot be
-- shadowed by anything the target declares.  The alias is Uppercase because the
-- parser requires it of every module alias.
--
-- A second `import test` line beside the target's own is accepted (imports are
-- name lists, not module claims), and the target must already import `test` or
-- its bodies could not have produced an `Expectation`.
--
-- ⚠️ `main` MUST be a zero-arg VALUE. `main () = …` is a silent no-op
-- ([T-MAIN-ZERO-ARG]), which here would present as every test aborting.
-- Referencing every `__tse_i__` from `main` is also what keeps `dceFilter` from
-- dropping them.
expectationAlias : String
expectationAlias = "MdkProbeTest__"

probeSource : String -> List (String, Int, Expr) -> String
probeSource tsrc tests =
  joinNl
    (["import test as \{expectationAlias}", "", tsrc, ""]
      ++ testBindings 0 tests
      ++ ["main ="]
      ++ mainLines 0 tests
      ++ ["  putStrLn \"\{sentinelFor endTag}\"", ""])

bindingName : Int -> String
bindingName i = "__ts_\{intToString i}__"

printerName : Int -> String
printerName i = "__tse_\{intToString i}__"

valueName : Int -> String
valueName i = "__tsv_\{intToString i}__"

-- Per test: the body as a binding, plus a printer that emits the constructor
-- tag and the three rendered fields between sentinels.
--
-- ⚠️ BOTH take a `Unit` parameter, and the body's is load-bearing, not
-- symmetry.  MEASURED: the native backend evaluates a top-level NULLARY binding
-- eagerly, before `main` runs — `boom = panic "boom"` kills the program before
-- `main`'s first `putStrLn` reaches stdout, where the interpreter prints it
-- first.  As nullary bindings, every test body would therefore be forced at
-- startup, so one panicking test would abort the probe before ANY sentinel was
-- printed and the whole file would report as one undifferentiated abort.  Under
-- a parameter the body is evaluated where it is called — inside `main`, in test
-- order — which is what gives the abort rule its per-test attribution.
testBindings : Int -> List (String, Int, Expr) -> List String
testBindings _ [] = []
testBindings i ((_, _, body) :: rest) =
  [declToString (DFunDef False (bindingName i) [PWild] body), ""]
    ++ printerDecl i
    ++ testBindings (i + 1) rest

-- The body is forced by the `let` BEFORE the first field sentinel, which is
-- what keeps the abort rule's attribution: a body that panics leaves its own
-- `<i>.start` chunk unterminated, and whatever the body printed on its own
-- account lands in that chunk rather than inside a field.
printerDecl : Int -> List String
printerDecl i =
  ["\{printerName i} _ =", "  let \{valueName i} = \{bindingName i} ()"]
    ++ emit i "tag" (accessor "expectationTag" i)
    ++ emit i "msg" (accessor "expectationMessage" i)
    ++ emit i "exp" (accessor "expectationExpected" i)
    ++ lastEmit i "act" (accessor "expectationActual" i)
    ++ [""]

accessor : String -> Int -> String
accessor f i = "\{expectationAlias}.\{f} \{valueName i}"

emit : Int -> String -> String -> List String
emit i f expr = [
  "  let _ = putStrLn \"\{sentinelFor (fieldTag i f)}\"",
  "  let _ = \{valuePrintExpr expr}",
]

lastEmit : Int -> String -> String -> List String
lastEmit i f expr = [
  "  let _ = putStrLn \"\{sentinelFor (fieldTag i f)}\"",
  "  \{valuePrintExpr expr}",
]

mainLines : Int -> List (String, Int, Expr) -> List String
mainLines _ [] = []
mainLines i (_ :: rest) =
  [
      "  let _ = putStrLn \"\{sentinelFor (startTag i)}\"",
      "  let _ = \{printerName i} ()",
    ]
    ++ mainLines (i + 1) rest

-- ── reading the probe's stdout back ─────────────────────────────────────────

-- A complete field: present, closed by a following sentinel, and decodable
-- back from the quoted form the probe printed it in.
completeField : List Chunk -> Int -> String -> Option String
completeField chunks i f = match lookupChunk (fieldTag i f) chunks
  Some (Chunk _ ls True) => decodeValue ls
  _ => None

startedTest : List Chunk -> Int -> Bool
startedTest chunks i = match lookupChunk (startTag i) chunks
  Some _ => True
  None => False

-- A transcript carrying a sentinel line this engine did not write.  Values are
-- printed quoted so a value cannot spell one; a test's own `println` output
-- still can, and reaching here means one did.  Every test is `Errored`: no
-- chunk in such a transcript is known to belong to the test whose tag it wears.
forgedTranscript : String
forgedTranscript =
  "native test runner: the probe printed a sentinel line this engine did not write, so the transcript no longer says which test each value belongs to. No verdict was read from it."

-- ⚠️ THE ABORT RULE.  A test whose four fields are not all complete is
-- `Errored` NAMING the abort.  It is never dropped and never treated as a pass.
-- A test that had STARTED when the probe died is named as the one that died in;
-- one that never started is named as never reached.
abortNote : Int -> String -> String
abortNote code errOut =
  let detail = firstNonEmptyLine (splitNl errOut)
  let suffix = if detail == "" then "" else " — " ++ detail
  "native test run ended (probe exit \{intToString code})\{suffix}"

startedNote : String -> String
startedNote note = "\{note}; the abort happened while this test was running"

notReachedNote : String -> String
notReachedNote note = "\{note} before this test was reported"

renderAll : List Chunk ->
  String ->
  Int ->
  List (String, Int, Expr) ->
  List ExResult
renderAll _ _ _ [] = []
renderAll chunks note i (_ :: rest) =
  renderOne chunks note i :: renderAll chunks note (i + 1) rest

renderOne : List Chunk -> String -> Int -> ExResult
renderOne chunks note i = match completeField chunks i "act"
  None =>
    if startedTest chunks i then
      Errored (startedNote note)
    else
      Errored (notReachedNote note)
  Some actual =>
    fromFields
      note
      (completeField chunks i "tag")
      (completeField chunks i "msg")
      (completeField chunks i "exp")
      actual

-- The driver's judgement, and the only place it is made: the probe reported a
-- constructor tag and three rendered strings, and `Pass` is what a passing test
-- looks like.  An unrecognized tag is an error, not a pass.
fromFields : String ->
  Option String ->
  Option String ->
  Option String ->
  String ->
  ExResult
fromFields _ (Some "Pass") _ (Some expected) actual = Pass expected actual
fromFields _ (Some "Fail") (Some msg) (Some expected) actual =
  Fail msg expected actual
fromFields note _ _ _ _ =
  Errored
    "native test runner: the probe's output for this test was incomplete (\{note})"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DFunDef" false) (mem "Expr" false) (mem "PWild" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "ppBuildReport" false) (mem "makeTempDir" false) (mem "cleanupTempDir" false) (mem "runBuildNativeRoots" false) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false) (mem "baseOf" false) (mem "dirOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "splitNl" false) (mem "anyList" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "ExResult" true))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "Chunk" true) (mem "chunksOf" false) (mem "decodeValue" false) (mem "endTag" false) (mem "firstNonEmptyLine" false) (mem "lookupChunk" false) (mem "sentinelLine" false) (mem "tagsInOrder" false) (mem "valuePrintExpr" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "declToString" false))))
(DTypeSig false "sentinelPrefix" (TyCon "String"))
(DFunDef false "sentinelPrefix" () (ELit (LString "@@__mdk_native_test__@@ ")))
(DTypeSig false "sentinelFor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sentinelFor" ((PVar "tag")) (EApp (EApp (EVar "sentinelLine") (EVar "sentinelPrefix")) (EVar "tag")))
(DTypeSig false "startTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "startTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ".start"))))
(DTypeSig false "fieldTag" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "fieldTag" ((PVar "i") (PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "."))) (EApp (EVar "display") (EVar "f"))) (ELit (LString ""))))
(DTypeSig false "expectedTags" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expectedTags" (PWild (PList)) (EListLit (EVar "endTag")))
(DFunDef false "expectedTags" ((PVar "i") (PCons PWild (PVar "rest"))) (EBinOp "++" (EListLit (EApp (EVar "startTag") (EVar "i")) (EApp (EApp (EVar "fieldTag") (EVar "i")) (ELit (LString "tag"))) (EApp (EApp (EVar "fieldTag") (EVar "i")) (ELit (LString "msg"))) (EApp (EApp (EVar "fieldTag") (EVar "i")) (ELit (LString "exp"))) (EApp (EApp (EVar "fieldTag") (EVar "i")) (ELit (LString "act")))) (EApp (EApp (EVar "expectedTags") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "nativeTestSkipReason" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "nativeTestSkipReason" ((PVar "target") (PVar "userDecls")) (EIf (EApp (EVar "definesMain") (EVar "userDecls")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: SKIPPED ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString " — it already defines a top-level `main`, which the synthesized test entry point would collide with. No test was executed natively.")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "definesMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "definesMain" ((PVar "decls")) (EApp (EApp (EVar "anyList") (EVar "isMainDef")) (EVar "decls")))
(DTypeSig false "isMainDef" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isMainDef" ((PCon "DFunDef" PWild (PLit (LString "main")) PWild PWild)) (EVar "True"))
(DFunDef false "isMainDef" (PWild) (EVar "False"))
(DTypeSig true "runNativeTests" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "ExResult"))))))))
(DFunDef false "runNativeTests" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "tests")) (EMatch (EApp (EApp (EApp (EApp (EVar "nativeRendered") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "tests")) (arm (PCon "Err" (PVar "reason")) () (EApp (EApp (EVar "map") (ELam (PWild) (EApp (EVar "Errored") (EVar "reason")))) (EVar "tests"))) (arm (PCon "Ok" (PVar "results")) () (EVar "results"))))
(DTypeSig false "nativeRendered" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ExResult")))))))))
(DFunDef false "nativeRendered" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "tests")) (EMatch (EApp (EApp (EVar "nativeTestSkipReason") (EVar "target")) (EVar "userDecls")) (arm (PCon "Some" (PVar "reason")) () (EApp (EVar "Err") (EVar "reason"))) (arm (PCon "None") () (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: could not create a scratch directory: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EVar "runInTmp") (EVar "target")) (EVar "tsrc")) (EVar "tests")) (EVar "tmpDir"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "results"))))))))
(DTypeSig false "scratchManifest" (TyCon "String"))
(DFunDef false "scratchManifest" () (ELit (LString "[project]\nname = \"medaka_native_test\"\n")))
(DTypeSig false "scratchEntryName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "scratchEntryName" ((PVar "target")) (EBinOp "++" (ELit (LString "ts_")) (EApp (EVar "baseOf") (EVar "target"))))
(DTypeSig false "runInTmp" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ExResult")))))))))
(DFunDef false "runInTmp" ((PVar "target") (PVar "tsrc") (PVar "tests") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "entryPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (EApp (EVar "scratchEntryName") (EVar "target")))) (DoLet false false (PVar "outPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "ts_probe")))) (DoLet false false PWild (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "medaka.toml")))) (EVar "scratchManifest"))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "entryPath")) (EApp (EApp (EVar "probeSource") (EVar "tsrc")) (EVar "tests"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: could not write the probe source: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "buildAndRun") (EVar "target")) (EVar "entryPath")) (EVar "outPath")) (EVar "tmpDir")) (EVar "tests")))))))
(DTypeSig false "buildAndRun" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ExResult"))))))))))
(DFunDef false "buildAndRun" ((PVar "target") (PVar "entryPath") (PVar "outPath") (PVar "tmpDir") (PVar "tests")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "extraRoots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeRoots") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "entryPath")) (EVar "outPath")) (EVar "tmpDir")) (EVar "False")) (EVar "extraRoots")) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: could not build ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString " natively\n"))) (EApp (EVar "display") (EApp (EVar "ppBuildReport") (EVar "rep")))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (EVar "outPath")) (EListLit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: could not run the compiled probe: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "errOut"))) () (EBlock (DoLet false false (PVar "chunks") (EApp (EApp (EVar "chunksOf") (EVar "sentinelPrefix")) (EApp (EVar "splitNl") (EVar "out")))) (DoExpr (EIf (EApp (EApp (EVar "tagsInOrder") (EApp (EApp (EVar "expectedTags") (ELit (LInt 0))) (EVar "tests"))) (EVar "chunks")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "renderAll") (EVar "chunks")) (EApp (EApp (EVar "abortNote") (EVar "code")) (EVar "errOut"))) (ELit (LInt 0))) (EVar "tests"))) (EApp (EVar "Err") (EVar "forgedTranscript"))))))))))))
(DTypeSig false "expectationAlias" (TyCon "String"))
(DFunDef false "expectationAlias" () (ELit (LString "MdkProbeTest__")))
(DTypeSig false "probeSource" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyCon "String"))))
(DFunDef false "probeSource" ((PVar "tsrc") (PVar "tests")) (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "import test as ")) (EApp (EVar "display") (EVar "expectationAlias"))) (ELit (LString ""))) (ELit (LString "")) (EVar "tsrc") (ELit (LString ""))) (EApp (EApp (EVar "testBindings") (ELit (LInt 0))) (EVar "tests"))) (EListLit (ELit (LString "main =")))) (EApp (EApp (EVar "mainLines") (ELit (LInt 0))) (EVar "tests"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  putStrLn \"")) (EApp (EVar "display") (EApp (EVar "sentinelFor") (EVar "endTag")))) (ELit (LString "\""))) (ELit (LString ""))))))
(DTypeSig false "bindingName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "bindingName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "__ts_")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "__"))))
(DTypeSig false "printerName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "printerName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tse_")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "__"))))
(DTypeSig false "valueName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "valueName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tsv_")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "__"))))
(DTypeSig false "testBindings" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "testBindings" (PWild (PList)) (EListLit))
(DFunDef false "testBindings" ((PVar "i") (PCons (PTuple PWild PWild (PVar "body")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EListLit (EApp (EVar "declToString") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EApp (EVar "bindingName") (EVar "i"))) (EListLit (EVar "PWild"))) (EVar "body"))) (ELit (LString ""))) (EApp (EVar "printerDecl") (EVar "i"))) (EApp (EApp (EVar "testBindings") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "printerDecl" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "printerDecl" ((PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "printerName") (EVar "i")))) (ELit (LString " _ ="))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let ")) (EApp (EVar "display") (EApp (EVar "valueName") (EVar "i")))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "bindingName") (EVar "i")))) (ELit (LString " ()")))) (EApp (EApp (EApp (EVar "emit") (EVar "i")) (ELit (LString "tag"))) (EApp (EApp (EVar "accessor") (ELit (LString "expectationTag"))) (EVar "i")))) (EApp (EApp (EApp (EVar "emit") (EVar "i")) (ELit (LString "msg"))) (EApp (EApp (EVar "accessor") (ELit (LString "expectationMessage"))) (EVar "i")))) (EApp (EApp (EApp (EVar "emit") (EVar "i")) (ELit (LString "exp"))) (EApp (EApp (EVar "accessor") (ELit (LString "expectationExpected"))) (EVar "i")))) (EApp (EApp (EApp (EVar "lastEmit") (EVar "i")) (ELit (LString "act"))) (EApp (EApp (EVar "accessor") (ELit (LString "expectationActual"))) (EVar "i")))) (EListLit (ELit (LString "")))))
(DTypeSig false "accessor" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "accessor" ((PVar "f") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "expectationAlias"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "f"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "valueName") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "emit" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "emit" ((PVar "i") (PVar "f") (PVar "expr")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = putStrLn \"")) (EApp (EVar "display") (EApp (EVar "sentinelFor") (EApp (EApp (EVar "fieldTag") (EVar "i")) (EVar "f"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "valuePrintExpr") (EVar "expr")))) (ELit (LString "")))))
(DTypeSig false "lastEmit" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lastEmit" ((PVar "i") (PVar "f") (PVar "expr")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = putStrLn \"")) (EApp (EVar "display") (EApp (EVar "sentinelFor") (EApp (EApp (EVar "fieldTag") (EVar "i")) (EVar "f"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EApp (EVar "valuePrintExpr") (EVar "expr")))) (ELit (LString "")))))
(DTypeSig false "mainLines" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "mainLines" (PWild (PList)) (EListLit))
(DFunDef false "mainLines" ((PVar "i") (PCons PWild (PVar "rest"))) (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = putStrLn \"")) (EApp (EVar "display") (EApp (EVar "sentinelFor") (EApp (EVar "startTag") (EVar "i"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EVar "display") (EApp (EVar "printerName") (EVar "i")))) (ELit (LString " ()")))) (EApp (EApp (EVar "mainLines") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "completeField" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "completeField" ((PVar "chunks") (PVar "i") (PVar "f")) (EMatch (EApp (EApp (EVar "lookupChunk") (EApp (EApp (EVar "fieldTag") (EVar "i")) (EVar "f"))) (EVar "chunks")) (arm (PCon "Some" (PCon "Chunk" PWild (PVar "ls") (PCon "True"))) () (EApp (EVar "decodeValue") (EVar "ls"))) (arm PWild () (EVar "None"))))
(DTypeSig false "startedTest" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "startedTest" ((PVar "chunks") (PVar "i")) (EMatch (EApp (EApp (EVar "lookupChunk") (EApp (EVar "startTag") (EVar "i"))) (EVar "chunks")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "forgedTranscript" (TyCon "String"))
(DFunDef false "forgedTranscript" () (ELit (LString "native test runner: the probe printed a sentinel line this engine did not write, so the transcript no longer says which test each value belongs to. No verdict was read from it.")))
(DTypeSig false "abortNote" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "abortNote" ((PVar "code") (PVar "errOut")) (EBlock (DoLet false false (PVar "detail") (EApp (EVar "firstNonEmptyLine") (EApp (EVar "splitNl") (EVar "errOut")))) (DoLet false false (PVar "suffix") (EIf (EBinOp "==" (EVar "detail") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (ELit (LString " — ")) (EVar "detail")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native test run ended (probe exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))) (EApp (EVar "display") (EVar "suffix"))) (ELit (LString ""))))))
(DTypeSig false "startedNote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "startedNote" ((PVar "note")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "note"))) (ELit (LString "; the abort happened while this test was running"))))
(DTypeSig false "notReachedNote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "notReachedNote" ((PVar "note")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "note"))) (ELit (LString " before this test was reported"))))
(DTypeSig false "renderAll" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "ExResult")))))))
(DFunDef false "renderAll" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "renderAll" ((PVar "chunks") (PVar "note") (PVar "i") (PCons PWild (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "renderOne") (EVar "chunks")) (EVar "note")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "renderAll") (EVar "chunks")) (EVar "note")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "renderOne" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "ExResult")))))
(DFunDef false "renderOne" ((PVar "chunks") (PVar "note") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "completeField") (EVar "chunks")) (EVar "i")) (ELit (LString "act"))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "startedTest") (EVar "chunks")) (EVar "i")) (EApp (EVar "Errored") (EApp (EVar "startedNote") (EVar "note"))) (EApp (EVar "Errored") (EApp (EVar "notReachedNote") (EVar "note"))))) (arm (PCon "Some" (PVar "actual")) () (EApp (EApp (EApp (EApp (EApp (EVar "fromFields") (EVar "note")) (EApp (EApp (EApp (EVar "completeField") (EVar "chunks")) (EVar "i")) (ELit (LString "tag")))) (EApp (EApp (EApp (EVar "completeField") (EVar "chunks")) (EVar "i")) (ELit (LString "msg")))) (EApp (EApp (EApp (EVar "completeField") (EVar "chunks")) (EVar "i")) (ELit (LString "exp")))) (EVar "actual")))))
(DTypeSig false "fromFields" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "ExResult")))))))
(DFunDef false "fromFields" (PWild (PCon "Some" (PLit (LString "Pass"))) PWild (PCon "Some" (PVar "expected")) (PVar "actual")) (EApp (EApp (EVar "Pass") (EVar "expected")) (EVar "actual")))
(DFunDef false "fromFields" (PWild (PCon "Some" (PLit (LString "Fail"))) (PCon "Some" (PVar "msg")) (PCon "Some" (PVar "expected")) (PVar "actual")) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (EVar "expected")) (EVar "actual")))
(DFunDef false "fromFields" ((PVar "note") PWild PWild PWild PWild) (EApp (EVar "Errored") (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: the probe's output for this test was incomplete (")) (EApp (EVar "display") (EVar "note"))) (ELit (LString ")")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DFunDef" false) (mem "Expr" false) (mem "PWild" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "ppBuildReport" false) (mem "makeTempDir" false) (mem "cleanupTempDir" false) (mem "runBuildNativeRoots" false) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false) (mem "baseOf" false) (mem "dirOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "splitNl" false) (mem "anyList" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "ExResult" true))))
(DUse false (UseGroup ("tools" "probe_transcript") ((mem "Chunk" true) (mem "chunksOf" false) (mem "decodeValue" false) (mem "endTag" false) (mem "firstNonEmptyLine" false) (mem "lookupChunk" false) (mem "sentinelLine" false) (mem "tagsInOrder" false) (mem "valuePrintExpr" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "declToString" false))))
(DTypeSig false "sentinelPrefix" (TyCon "String"))
(DFunDef false "sentinelPrefix" () (ELit (LString "@@__mdk_native_test__@@ ")))
(DTypeSig false "sentinelFor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sentinelFor" ((PVar "tag")) (EApp (EApp (EVar "sentinelLine") (EVar "sentinelPrefix")) (EVar "tag")))
(DTypeSig false "startTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "startTag" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ".start"))))
(DTypeSig false "fieldTag" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "fieldTag" ((PVar "i") (PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString ""))))
(DTypeSig false "expectedTags" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expectedTags" (PWild (PList)) (EListLit (EVar "endTag")))
(DFunDef false "expectedTags" ((PVar "i") (PCons PWild (PVar "rest"))) (EBinOp "++" (EListLit (EApp (EVar "startTag") (EVar "i")) (EApp (EApp (EVar "fieldTag") (EVar "i")) (ELit (LString "tag"))) (EApp (EApp (EVar "fieldTag") (EVar "i")) (ELit (LString "msg"))) (EApp (EApp (EVar "fieldTag") (EVar "i")) (ELit (LString "exp"))) (EApp (EApp (EVar "fieldTag") (EVar "i")) (ELit (LString "act")))) (EApp (EApp (EVar "expectedTags") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "nativeTestSkipReason" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "nativeTestSkipReason" ((PVar "target") (PVar "userDecls")) (EIf (EApp (EVar "definesMain") (EVar "userDecls")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: SKIPPED ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString " — it already defines a top-level `main`, which the synthesized test entry point would collide with. No test was executed natively.")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "definesMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "definesMain" ((PVar "decls")) (EApp (EApp (EVar "anyList") (EVar "isMainDef")) (EVar "decls")))
(DTypeSig false "isMainDef" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isMainDef" ((PCon "DFunDef" PWild (PLit (LString "main")) PWild PWild)) (EVar "True"))
(DFunDef false "isMainDef" (PWild) (EVar "False"))
(DTypeSig true "runNativeTests" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "ExResult"))))))))
(DFunDef false "runNativeTests" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "tests")) (EMatch (EApp (EApp (EApp (EApp (EVar "nativeRendered") (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "tests")) (arm (PCon "Err" (PVar "reason")) () (EApp (EApp (EMethodRef "map") (ELam (PWild) (EApp (EVar "Errored") (EVar "reason")))) (EVar "tests"))) (arm (PCon "Ok" (PVar "results")) () (EVar "results"))))
(DTypeSig false "nativeRendered" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ExResult")))))))))
(DFunDef false "nativeRendered" ((PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "tests")) (EMatch (EApp (EApp (EVar "nativeTestSkipReason") (EVar "target")) (EVar "userDecls")) (arm (PCon "Some" (PVar "reason")) () (EApp (EVar "Err") (EVar "reason"))) (arm (PCon "None") () (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: could not create a scratch directory: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EVar "runInTmp") (EVar "target")) (EVar "tsrc")) (EVar "tests")) (EVar "tmpDir"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "results"))))))))
(DTypeSig false "scratchManifest" (TyCon "String"))
(DFunDef false "scratchManifest" () (ELit (LString "[project]\nname = \"medaka_native_test\"\n")))
(DTypeSig false "scratchEntryName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "scratchEntryName" ((PVar "target")) (EBinOp "++" (ELit (LString "ts_")) (EApp (EVar "baseOf") (EVar "target"))))
(DTypeSig false "runInTmp" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ExResult")))))))))
(DFunDef false "runInTmp" ((PVar "target") (PVar "tsrc") (PVar "tests") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "entryPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (EApp (EVar "scratchEntryName") (EVar "target")))) (DoLet false false (PVar "outPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "ts_probe")))) (DoLet false false PWild (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "medaka.toml")))) (EVar "scratchManifest"))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "entryPath")) (EApp (EApp (EVar "probeSource") (EVar "tsrc")) (EVar "tests"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: could not write the probe source: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "buildAndRun") (EVar "target")) (EVar "entryPath")) (EVar "outPath")) (EVar "tmpDir")) (EVar "tests")))))))
(DTypeSig false "buildAndRun" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ExResult"))))))))))
(DFunDef false "buildAndRun" ((PVar "target") (PVar "entryPath") (PVar "outPath") (PVar "tmpDir") (PVar "tests")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "extraRoots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeRoots") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "entryPath")) (EVar "outPath")) (EVar "tmpDir")) (EVar "False")) (EVar "extraRoots")) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: could not build ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString " natively\n"))) (EApp (EMethodRef "display") (EApp (EVar "ppBuildReport") (EVar "rep")))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (EVar "outPath")) (EListLit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: could not run the compiled probe: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "errOut"))) () (EBlock (DoLet false false (PVar "chunks") (EApp (EApp (EVar "chunksOf") (EVar "sentinelPrefix")) (EApp (EVar "splitNl") (EVar "out")))) (DoExpr (EIf (EApp (EApp (EVar "tagsInOrder") (EApp (EApp (EVar "expectedTags") (ELit (LInt 0))) (EVar "tests"))) (EVar "chunks")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "renderAll") (EVar "chunks")) (EApp (EApp (EVar "abortNote") (EVar "code")) (EVar "errOut"))) (ELit (LInt 0))) (EVar "tests"))) (EApp (EVar "Err") (EVar "forgedTranscript"))))))))))))
(DTypeSig false "expectationAlias" (TyCon "String"))
(DFunDef false "expectationAlias" () (ELit (LString "MdkProbeTest__")))
(DTypeSig false "probeSource" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyCon "String"))))
(DFunDef false "probeSource" ((PVar "tsrc") (PVar "tests")) (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "import test as ")) (EApp (EMethodRef "display") (EVar "expectationAlias"))) (ELit (LString ""))) (ELit (LString "")) (EVar "tsrc") (ELit (LString ""))) (EApp (EApp (EVar "testBindings") (ELit (LInt 0))) (EVar "tests"))) (EListLit (ELit (LString "main =")))) (EApp (EApp (EVar "mainLines") (ELit (LInt 0))) (EVar "tests"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  putStrLn \"")) (EApp (EMethodRef "display") (EApp (EVar "sentinelFor") (EVar "endTag")))) (ELit (LString "\""))) (ELit (LString ""))))))
(DTypeSig false "bindingName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "bindingName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "__ts_")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "__"))))
(DTypeSig false "printerName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "printerName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tse_")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "__"))))
(DTypeSig false "valueName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "valueName" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tsv_")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "__"))))
(DTypeSig false "testBindings" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "testBindings" (PWild (PList)) (EListLit))
(DFunDef false "testBindings" ((PVar "i") (PCons (PTuple PWild PWild (PVar "body")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EListLit (EApp (EVar "declToString") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EApp (EVar "bindingName") (EVar "i"))) (EListLit (EVar "PWild"))) (EVar "body"))) (ELit (LString ""))) (EApp (EVar "printerDecl") (EVar "i"))) (EApp (EApp (EVar "testBindings") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "printerDecl" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "printerDecl" ((PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "printerName") (EVar "i")))) (ELit (LString " _ ="))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  let ")) (EApp (EMethodRef "display") (EApp (EVar "valueName") (EVar "i")))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "bindingName") (EVar "i")))) (ELit (LString " ()")))) (EApp (EApp (EApp (EVar "emit") (EVar "i")) (ELit (LString "tag"))) (EApp (EApp (EVar "accessor") (ELit (LString "expectationTag"))) (EVar "i")))) (EApp (EApp (EApp (EVar "emit") (EVar "i")) (ELit (LString "msg"))) (EApp (EApp (EVar "accessor") (ELit (LString "expectationMessage"))) (EVar "i")))) (EApp (EApp (EApp (EVar "emit") (EVar "i")) (ELit (LString "exp"))) (EApp (EApp (EVar "accessor") (ELit (LString "expectationExpected"))) (EVar "i")))) (EApp (EApp (EApp (EVar "lastEmit") (EVar "i")) (ELit (LString "act"))) (EApp (EApp (EVar "accessor") (ELit (LString "expectationActual"))) (EVar "i")))) (EListLit (ELit (LString "")))))
(DTypeSig false "accessor" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "accessor" ((PVar "f") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "expectationAlias"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "valueName") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "emit" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "emit" ((PVar "i") (PVar "f") (PVar "expr")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = putStrLn \"")) (EApp (EMethodRef "display") (EApp (EVar "sentinelFor") (EApp (EApp (EVar "fieldTag") (EVar "i")) (EVar "f"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "valuePrintExpr") (EVar "expr")))) (ELit (LString "")))))
(DTypeSig false "lastEmit" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lastEmit" ((PVar "i") (PVar "f") (PVar "expr")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = putStrLn \"")) (EApp (EMethodRef "display") (EApp (EVar "sentinelFor") (EApp (EApp (EVar "fieldTag") (EVar "i")) (EVar "f"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EApp (EVar "valuePrintExpr") (EVar "expr")))) (ELit (LString "")))))
(DTypeSig false "mainLines" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "mainLines" (PWild (PList)) (EListLit))
(DFunDef false "mainLines" ((PVar "i") (PCons PWild (PVar "rest"))) (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = putStrLn \"")) (EApp (EMethodRef "display") (EApp (EVar "sentinelFor") (EApp (EVar "startTag") (EVar "i"))))) (ELit (LString "\""))) (EBinOp "++" (EBinOp "++" (ELit (LString "  let _ = ")) (EApp (EMethodRef "display") (EApp (EVar "printerName") (EVar "i")))) (ELit (LString " ()")))) (EApp (EApp (EVar "mainLines") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "completeField" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "completeField" ((PVar "chunks") (PVar "i") (PVar "f")) (EMatch (EApp (EApp (EVar "lookupChunk") (EApp (EApp (EVar "fieldTag") (EVar "i")) (EVar "f"))) (EVar "chunks")) (arm (PCon "Some" (PCon "Chunk" PWild (PVar "ls") (PCon "True"))) () (EApp (EVar "decodeValue") (EVar "ls"))) (arm PWild () (EVar "None"))))
(DTypeSig false "startedTest" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "startedTest" ((PVar "chunks") (PVar "i")) (EMatch (EApp (EApp (EVar "lookupChunk") (EApp (EVar "startTag") (EVar "i"))) (EVar "chunks")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "forgedTranscript" (TyCon "String"))
(DFunDef false "forgedTranscript" () (ELit (LString "native test runner: the probe printed a sentinel line this engine did not write, so the transcript no longer says which test each value belongs to. No verdict was read from it.")))
(DTypeSig false "abortNote" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "abortNote" ((PVar "code") (PVar "errOut")) (EBlock (DoLet false false (PVar "detail") (EApp (EVar "firstNonEmptyLine") (EApp (EVar "splitNl") (EVar "errOut")))) (DoLet false false (PVar "suffix") (EIf (EBinOp "==" (EVar "detail") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (ELit (LString " — ")) (EVar "detail")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "native test run ended (probe exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))) (EApp (EMethodRef "display") (EVar "suffix"))) (ELit (LString ""))))))
(DTypeSig false "startedNote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "startedNote" ((PVar "note")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "note"))) (ELit (LString "; the abort happened while this test was running"))))
(DTypeSig false "notReachedNote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "notReachedNote" ((PVar "note")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "note"))) (ELit (LString " before this test was reported"))))
(DTypeSig false "renderAll" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "ExResult")))))))
(DFunDef false "renderAll" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "renderAll" ((PVar "chunks") (PVar "note") (PVar "i") (PCons PWild (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "renderOne") (EVar "chunks")) (EVar "note")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "renderAll") (EVar "chunks")) (EVar "note")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "renderOne" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "ExResult")))))
(DFunDef false "renderOne" ((PVar "chunks") (PVar "note") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "completeField") (EVar "chunks")) (EVar "i")) (ELit (LString "act"))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "startedTest") (EVar "chunks")) (EVar "i")) (EApp (EVar "Errored") (EApp (EVar "startedNote") (EVar "note"))) (EApp (EVar "Errored") (EApp (EVar "notReachedNote") (EVar "note"))))) (arm (PCon "Some" (PVar "actual")) () (EApp (EApp (EApp (EApp (EApp (EVar "fromFields") (EVar "note")) (EApp (EApp (EApp (EVar "completeField") (EVar "chunks")) (EVar "i")) (ELit (LString "tag")))) (EApp (EApp (EApp (EVar "completeField") (EVar "chunks")) (EVar "i")) (ELit (LString "msg")))) (EApp (EApp (EApp (EVar "completeField") (EVar "chunks")) (EVar "i")) (ELit (LString "exp")))) (EVar "actual")))))
(DTypeSig false "fromFields" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "ExResult")))))))
(DFunDef false "fromFields" (PWild (PCon "Some" (PLit (LString "Pass"))) PWild (PCon "Some" (PVar "expected")) (PVar "actual")) (EApp (EApp (EVar "Pass") (EVar "expected")) (EVar "actual")))
(DFunDef false "fromFields" (PWild (PCon "Some" (PLit (LString "Fail"))) (PCon "Some" (PVar "msg")) (PCon "Some" (PVar "expected")) (PVar "actual")) (EApp (EApp (EApp (EVar "Fail") (EVar "msg")) (EVar "expected")) (EVar "actual")))
(DFunDef false "fromFields" ((PVar "note") PWild PWild PWild PWild) (EApp (EVar "Errored") (EBinOp "++" (EBinOp "++" (ELit (LString "native test runner: the probe's output for this test was incomplete (")) (EApp (EMethodRef "display") (EVar "note"))) (ELit (LString ")")))))
