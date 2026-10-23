# META
source_lines=320
stages=DESUGAR,MARK
# SOURCE
{- interface_cmd.mdk: `medaka interface write|show|verify`, the driver for the
   prelude interface file (`<module>.mdki`, the format of `types.interface_sexp`).

   `write` is the prelude's judge: it type-checks the module on the
   diagnostics arm under each named target profile, and only a module that
   checks clean under all of them leaves a file.  `show` prints a file's header
   and every published row.  `verify` compares the key a file was written
   under with the key its module has now. -}

import args.{
  ArgSpec, FlagSpec, spec, switch, valueList, withStrictDash, parseArgs, flag,
  flagValues, unknownFlagMessage
}
import io.{runCommandOk}
import list.{zip}
import string as S
import driver.build_cmd.{
  PreludeInputs(..), readPreludeFile, preludeInterfaceKey, faultComponent
}
import driver.diagnostics.{analyzeFrom, ppDiagCliSrc, diagIsError}
import driver.front_gate.{cliStdlibExports}
import frontend.parser.{parseLocated}
import support.path.{dirOf, baseName, joinPath}
import support.stage_count.{stageExit}
import support.util.{joinNl, joinWith}
import types.effect_rows.{Atom, renderAtom}
import types.interface_sexp.{
  PreludeInterfaceFile(..), InterfaceSection(..), encodeInterface,
  readInterface, renderFault, mergeSections
}
import types.prelude_interface.{
  PreludeInterface(..), InterfaceKey(..), keysMatch, currentPreludeInterface
}
import types.publish.{ppPubScheme}
import types.target_profile.{TargetProfile, lookupProfile, selectedProfile}

-- ── help ────────────────────────────────────────────────────────────────────

export
interfaceHelpText : String
interfaceHelpText = stringConcat [
  "medaka interface — Write, show and verify the prelude interface file\n",
  "\n",
  "Usage:\n",
  "  medaka interface write  <module.mdk> [--target <profile>]...\n",
  "  medaka interface show   <file.mdki>\n",
  "  medaka interface verify <module.mdk>\n",
  "\n",
  "  write   type-checks the module (the prelude's core, with runtime.mdk beside\n",
  "          it) under each --target profile and writes <module>.mdki beside it.\n",
  "          Without --target the profiles are the full IO join and\n",
  "          wasmgc/browser-worker.  A module with a type error leaves no file.\n",
  "  show    prints the header and every published row.\n",
  "  verify  prints `fresh`, `stale: <component>` or `missing`; exit 0 only on\n",
  "          `fresh`.\n",
  "\n",
  "  -h, --help  prints this help.\n",
]

writeSpec : ArgSpec
writeSpec =
  withStrictDash
    (spec "interface write" [
      helpSwitch,
      valueList
        ["--target"]
        "PROFILE"
        "a target profile whose IO join gets a section (repeatable)",
    ])

plainSpec : String -> ArgSpec
plainSpec verb = withStrictDash (spec verb [helpSwitch])

helpSwitch : FlagSpec
helpSwitch = switch ["--help", "-h"] "print this help"

-- ── the key ─────────────────────────────────────────────────────────────────

-- What [modulePath] is checked and keyed from: its directory as the stdlib, the
-- two prelude texts, and the compiler running now.
inputsOf : String -> String -> String -> PreludeInputs
inputsOf modulePath runtimeSrc coreSrc = PreludeInputs {
  pnStdlibDir = dirOf modulePath,
  pnRuntimeSrc = runtimeSrc,
  pnCoreSrc = coreSrc,
  pnCompiler = buildFingerprint (),
}

-- The interface file is named for the module it was built from.
interfacePath : String -> String
interfacePath modulePath = modulePath ++ "i"

runtimePathOf : String -> String
runtimePathOf modulePath = joinPath (dirOf modulePath) "runtime.mdk"

-- ── write ───────────────────────────────────────────────────────────────────

defaultTargets : List String
defaultTargets = ["", "wasmgc/browser-worker"]

profileOfTarget : String -> Result String (Option TargetProfile)
profileOfTarget "" = Ok None
profileOfTarget name = map Some (lookupProfile name)

-- The module checked as a user file under [profile], on the diagnostics arm: the
-- verdict.  A trivial program is then driven against the same prelude, which
-- leaves the prelude's interface in the process cache under the profile's IO
-- join (a drive of the prelude's own text as the user file leaves none).
-- Errors come back rendered.
driveUnder : PreludeInputs ->
  String ->
  Option TargetProfile ->
  <IO> Result String (List (List Atom, PreludeInterface))
driveUnder inputs modulePath profile =
  let saved = !selectedProfile
  selectedProfile := profile
  let exports = cliStdlibExports inputs.pnStdlibDir
  let runtimeSrc = inputs.pnRuntimeSrc
  let coreSrc = inputs.pnCoreSrc
  let errors =
    filter
      diagIsError
      (analyzeFrom exports "" runtimeSrc coreSrc (parseLocated coreSrc))
  let trivial = match errors
    [] => analyzeFrom exports "" runtimeSrc coreSrc (parseLocated "x = 1\n")
    _ => []
  selectedProfile := saved
  match (errors, length trivial)
    ([], _) => match currentPreludeInterface ()
      [] => Err "medaka interface write: the check left no prelude interface"
      sections => Ok (flatMap (s => map (j => (j, snd s)) (fst s)) sections)
    _ => Err (joinNl (map (ppDiagCliSrc coreSrc modulePath) errors))

-- The file for [modulePath] checked under [targets] (profile names, "" for the
-- full join; none given means the default targets).
export
buildInterfaceFile : String ->
  List String ->
  <IO> Result String PreludeInterfaceFile
buildInterfaceFile modulePath targets = do
  runtimeSrc <- readPreludeFile (runtimePathOf modulePath)
  coreSrc <- readPreludeFile modulePath
  profiles <- traverse profileOfTarget (if isEmpty targets then
    defaultTargets
  else
    targets)
  let inputs = inputsOf modulePath runtimeSrc coreSrc
  drives <- traverse (driveUnder inputs modulePath) profiles
  Ok PreludeInterfaceFile {
    ifKey = preludeInterfaceKey (baseName modulePath) inputs,
    ifSections = mergeSections (flatMap (d => d) drives),
  }

-- The text goes into a fresh directory beside the target and is renamed over
-- it, so a reader never sees a half-written file.  `mktemp -d` makes the
-- directory atomically, so concurrent writers, even of the same module, never
-- share a staging file; the directory is removed on every path.
writeAtomically : String -> String -> <IO> Result String Unit
writeAtomically path text =
  match runCommandOk "mktemp" ["-d", "\{path}.new.XXXXXX"]
    Err e => Err "cannot make a staging directory beside `\{path}`: \{e}"
    Ok (out, _) =>
      let dir = S.trim out
      let staging = joinPath dir (baseName path)
      let result = match writeFile staging text
        Err e => Err "cannot write `\{staging}`: \{e}"
        Ok _ => match rename staging path
          Ok _ => Ok ()
          Err e => Err "cannot move `\{staging}` to `\{path}`: \{e}"
      let _ = removeFile staging
      let _ = removeDir dir
      result

failWith : String -> <IO> Unit
-- The same two lines as `entries/entry_support.mdk`'s `failWith`; a tool cannot import an entry.
-- lint-disable-next-line rule-duplicate-body
failWith msg =
  let _ = ePutStrLn msg
  stageExit 1

writeCmd : String -> List String -> <IO> Unit
writeCmd modulePath targets
  | buildFingerprint () == "" =
    failWith
      "medaka interface write: this binary carries no build fingerprint (an unstamped build), so a file it wrote could not be told from another unstamped compiler's; build with `make medaka`"
  | otherwise = match buildInterfaceFile modulePath targets
    Err e => failWith e
    Ok file =>
      match writeAtomically (interfacePath modulePath) (encodeInterface file)
        Err e => failWith "medaka interface write: \{e}"
        Ok _ => putStrLn "wrote \{interfacePath modulePath}"

-- ── show ────────────────────────────────────────────────────────────────────

joinView : List Atom -> String
joinView j = joinWith "," (map renderAtom j)

sectionLines : Int -> Int -> InterfaceSection -> List String
sectionLines n total s =
  ["section \{n} of \{total}"]
    ++ map (j => "  join \{joinView j}") s.isJoins
    ++ map
      (row => "  row \{fst row} : \{ppPubScheme (snd row)}")
      s.isInterface.piCore

-- The header and every section of a decoded file; [digest] is the file's own.
export
showLines : String -> PreludeInterfaceFile -> List String
showLines digest f =
  let total = length f.ifSections
  ["format \{f.ifKey.ikFormat}"]
    ++ map (s => "source \{fst s} sha256 \{snd s}") f.ifKey.ikSources
    ++ [
      "compiler \{f.ifKey.ikCompiler}",
      "sections \{total}",
      "digest \{digest}",
    ]
    ++ flatMap
      (p => sectionLines (fst p) total (snd p))
      (zip [1..=total] f.ifSections)

showCmd : String -> <IO> Unit
showCmd path
  | S.endsWith ".mdk" path =
    failWith
      "medaka interface show: `\{path}` is a source file; show takes the `.mdki` that `medaka interface write` wrote beside it (`\{interfacePath path}`)"
  | otherwise = showFile path

showFile : String -> <IO> Unit
showFile path = match readFile path
  Err e => failWith "medaka interface show: cannot read `\{path}`: \{e}"
  Ok text => match readInterface text
    Err fault =>
      failWith "medaka interface show: `\{path}`: \{renderFault fault}"
    Ok (f, digest) => putStrLn (joinNl (showLines digest f))

-- ── verify ──────────────────────────────────────────────────────────────────

public export data Verdict = Fresh | Stale String | Missing

export
verdictText : Verdict -> String
verdictText Fresh = "fresh"
verdictText (Stale component) = "stale: \{component}"
verdictText Missing = "missing"

-- How [modulePath]'s interface file stands against the module's sources now.
export
verdictOf : String -> <IO> Verdict
verdictOf modulePath = match readFile (interfacePath modulePath)
  Err _ => Missing
  Ok text => match readInterface text
    Err fault => Stale (faultComponent fault)
    Ok (f, _) => match (
      readFile (runtimePathOf modulePath),
      readFile modulePath,
    )
      (Ok runtimeSrc, Ok coreSrc) =>
        match (keysMatch
          f.ifKey
          (preludeInterfaceKey
            (baseName modulePath)
            (inputsOf modulePath runtimeSrc coreSrc)))
          None => Fresh
          Some component => Stale component
      _ => Stale "sources"

verifyCmd : String -> <IO> Unit
verifyCmd modulePath =
  let verdict = verdictOf modulePath
  let _ = putStrLn (verdictText verdict)
  match verdict
    Fresh => ()
    _ => stageExit 1

-- ── dispatch ────────────────────────────────────────────────────────────────

printHelp : Unit -> <IO> Unit
printHelp _ =
  let _ = putStrLn interfaceHelpText
  stageExit 0

oneModule : ArgSpec -> List String -> (String -> <IO> Unit) -> <IO> Unit
oneModule sp argv run = match parseArgs sp argv
  Err m => failWith m
  Ok a =>
    if flag "--help" a then
      printHelp ()
    else match a.positionals
      [path] => run path
      [] => failWith "usage: \{sp.verb} <path>"
      _ :: extra :: _ => failWith (unknownFlagMessage sp extra)

writeArgs : List String -> <IO> Unit
writeArgs argv = match parseArgs writeSpec argv
  Err m => failWith m
  Ok a =>
    if flag "--help" a then
      printHelp ()
    else match a.positionals
      [path] => writeCmd path (flagValues "--target" a)
      [] =>
        failWith
          "usage: medaka interface write <module.mdk> [--target <profile>]..."
      _ :: extra :: _ => failWith (unknownFlagMessage writeSpec extra)

{- | `medaka interface <write|show|verify> …`. -}
export
runInterfaceCmd : List String -> <IO> Unit
runInterfaceCmd [] =
  failWith
    "usage: medaka interface write|verify <module.mdk>, medaka interface show <file.mdki>"
runInterfaceCmd ("write" :: rest) = writeArgs rest
runInterfaceCmd ("show" :: rest) =
  oneModule (plainSpec "interface show") rest showCmd
runInterfaceCmd ("verify" :: rest) =
  oneModule (plainSpec "interface verify") rest verifyCmd
runInterfaceCmd (sub :: _) =
  failWith
    "medaka interface: unknown subcommand '\{sub}' (expected: write, show, verify)"
# DESUGAR
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "FlagSpec" false) (mem "spec" false) (mem "switch" false) (mem "valueList" false) (mem "withStrictDash" false) (mem "parseArgs" false) (mem "flag" false) (mem "flagValues" false) (mem "unknownFlagMessage" false))))
(DUse false (UseGroup ("io") ((mem "runCommandOk" false))))
(DUse false (UseGroup ("list") ((mem "zip" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "PreludeInputs" true) (mem "readPreludeFile" false) (mem "preludeInterfaceKey" false) (mem "faultComponent" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeFrom" false) (mem "ppDiagCliSrc" false) (mem "diagIsError" false))))
(DUse false (UseGroup ("driver" "front_gate") ((mem "cliStdlibExports" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseLocated" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "baseName" false) (mem "joinPath" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "joinWith" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("types" "interface_sexp") ((mem "PreludeInterfaceFile" true) (mem "InterfaceSection" true) (mem "encodeInterface" false) (mem "readInterface" false) (mem "renderFault" false) (mem "mergeSections" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "PreludeInterface" true) (mem "InterfaceKey" true) (mem "keysMatch" false) (mem "currentPreludeInterface" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ppPubScheme" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "lookupProfile" false) (mem "selectedProfile" false))))
(DTypeSig true "interfaceHelpText" (TyCon "String"))
(DFunDef false "interfaceHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka interface — Write, show and verify the prelude interface file\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka interface write  <module.mdk> [--target <profile>]...\n")) (ELit (LString "  medaka interface show   <file.mdki>\n")) (ELit (LString "  medaka interface verify <module.mdk>\n")) (ELit (LString "\n")) (ELit (LString "  write   type-checks the module (the prelude's core, with runtime.mdk beside\n")) (ELit (LString "          it) under each --target profile and writes <module>.mdki beside it.\n")) (ELit (LString "          Without --target the profiles are the full IO join and\n")) (ELit (LString "          wasmgc/browser-worker.  A module with a type error leaves no file.\n")) (ELit (LString "  show    prints the header and every published row.\n")) (ELit (LString "  verify  prints `fresh`, `stale: <component>` or `missing`; exit 0 only on\n")) (ELit (LString "          `fresh`.\n")) (ELit (LString "\n")) (ELit (LString "  -h, --help  prints this help.\n")))))
(DTypeSig false "writeSpec" (TyCon "ArgSpec"))
(DFunDef false "writeSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "interface write"))) (EListLit (EVar "helpSwitch") (EApp (EApp (EApp (EVar "valueList") (EListLit (ELit (LString "--target")))) (ELit (LString "PROFILE"))) (ELit (LString "a target profile whose IO join gets a section (repeatable)")))))))
(DTypeSig false "plainSpec" (TyFun (TyCon "String") (TyCon "ArgSpec")))
(DFunDef false "plainSpec" ((PVar "verb")) (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (EVar "verb")) (EListLit (EVar "helpSwitch")))))
(DTypeSig false "helpSwitch" (TyCon "FlagSpec"))
(DFunDef false "helpSwitch" () (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--help")) (ELit (LString "-h")))) (ELit (LString "print this help"))))
(DTypeSig false "inputsOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "PreludeInputs")))))
(DFunDef false "inputsOf" ((PVar "modulePath") (PVar "runtimeSrc") (PVar "coreSrc")) (ERecordCreate "PreludeInputs" ((fa "pnStdlibDir" (EApp (EVar "dirOf") (EVar "modulePath"))) (fa "pnRuntimeSrc" (EVar "runtimeSrc")) (fa "pnCoreSrc" (EVar "coreSrc")) (fa "pnCompiler" (EApp (EVar "buildFingerprint") (ELit LUnit))))))
(DTypeSig false "interfacePath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "interfacePath" ((PVar "modulePath")) (EBinOp "++" (EVar "modulePath") (ELit (LString "i"))))
(DTypeSig false "runtimePathOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "runtimePathOf" ((PVar "modulePath")) (EApp (EApp (EVar "joinPath") (EApp (EVar "dirOf") (EVar "modulePath"))) (ELit (LString "runtime.mdk"))))
(DTypeSig false "defaultTargets" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "defaultTargets" () (EListLit (ELit (LString "")) (ELit (LString "wasmgc/browser-worker"))))
(DTypeSig false "profileOfTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "TargetProfile")))))
(DFunDef false "profileOfTarget" ((PLit (LString ""))) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "profileOfTarget" ((PVar "name")) (EApp (EApp (EVar "map") (EVar "Some")) (EApp (EVar "lookupProfile") (EVar "name"))))
(DTypeSig false "driveUnder" (TyFun (TyCon "PreludeInputs") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "TargetProfile")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "PreludeInterface")))))))))
(DFunDef false "driveUnder" ((PVar "inputs") (PVar "modulePath") (PVar "profile")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "selectedProfile"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "profile"))) (DoLet false false (PVar "exports") (EApp (EVar "cliStdlibExports") (EFieldAccess (EVar "inputs") "pnStdlibDir"))) (DoLet false false (PVar "runtimeSrc") (EFieldAccess (EVar "inputs") "pnRuntimeSrc")) (DoLet false false (PVar "coreSrc") (EFieldAccess (EVar "inputs") "pnCoreSrc")) (DoLet false false (PVar "errors") (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "exports")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (EVar "coreSrc"))))) (DoLet false false (PVar "trivial") (EMatch (EVar "errors") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "exports")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (ELit (LString "x = 1\n"))))) (arm PWild () (EListLit)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "saved"))) (DoExpr (EMatch (ETuple (EVar "errors") (EApp (EVar "length") (EVar "trivial"))) (arm (PTuple (PList) PWild) () (EMatch (EApp (EVar "currentPreludeInterface") (ELit LUnit)) (arm (PList) () (EApp (EVar "Err") (ELit (LString "medaka interface write: the check left no prelude interface")))) (arm (PVar "sections") () (EApp (EVar "Ok") (EApp (EApp (EVar "flatMap") (ELam ((PVar "s")) (EApp (EApp (EVar "map") (ELam ((PVar "j")) (ETuple (EVar "j") (EApp (EVar "snd") (EVar "s"))))) (EApp (EVar "fst") (EVar "s"))))) (EVar "sections")))))) (arm PWild () (EApp (EVar "Err") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "coreSrc")) (EVar "modulePath"))) (EVar "errors")))))))))
(DTypeSig true "buildInterfaceFile" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PreludeInterfaceFile"))))))
(DFunDef false "buildInterfaceFile" ((PVar "modulePath") (PVar "targets")) (EApp (EApp (EVar "andThen") (EApp (EVar "readPreludeFile") (EApp (EVar "runtimePathOf") (EVar "modulePath")))) (ELam ((PVar "runtimeSrc")) (EApp (EApp (EVar "andThen") (EApp (EVar "readPreludeFile") (EVar "modulePath"))) (ELam ((PVar "coreSrc")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "traverse") (EVar "profileOfTarget")) (EIf (EApp (EVar "isEmpty") (EVar "targets")) (EVar "defaultTargets") (EVar "targets")))) (ELam ((PVar "profiles")) (ELet false (PVar "inputs") (EApp (EApp (EApp (EVar "inputsOf") (EVar "modulePath")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "traverse") (EApp (EApp (EVar "driveUnder") (EVar "inputs")) (EVar "modulePath"))) (EVar "profiles"))) (ELam ((PVar "drives")) (EApp (EVar "Ok") (ERecordCreate "PreludeInterfaceFile" ((fa "ifKey" (EApp (EApp (EVar "preludeInterfaceKey") (EApp (EVar "baseName") (EVar "modulePath"))) (EVar "inputs"))) (fa "ifSections" (EApp (EVar "mergeSections") (EApp (EApp (EVar "flatMap") (ELam ((PVar "d")) (EVar "d"))) (EVar "drives")))))))))))))))))
(DTypeSig false "writeAtomically" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "writeAtomically" ((PVar "path") (PVar "text")) (EMatch (EApp (EApp (EVar "runCommandOk") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ".new.XXXXXX"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot make a staging directory beside `")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "dir") (EApp (EVar "S.trim") (EVar "out"))) (DoLet false false (PVar "staging") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EApp (EVar "baseName") (EVar "path")))) (DoLet false false (PVar "result") (EMatch (EApp (EApp (EVar "writeFile") (EVar "staging")) (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot write `")) (EApp (EVar "display") (EVar "staging"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "rename") (EVar "staging")) (EVar "path")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot move `")) (EApp (EVar "display") (EVar "staging"))) (ELit (LString "` to `"))) (EApp (EVar "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))))))) (DoLet false false PWild (EApp (EVar "removeFile") (EVar "staging"))) (DoLet false false PWild (EApp (EVar "removeDir") (EVar "dir"))) (DoExpr (EVar "result"))))))
(DTypeSig false "failWith" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "failWith" ((PVar "msg")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))
(DTypeSig false "writeCmd" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeCmd" ((PVar "modulePath") (PVar "targets")) (EIf (EBinOp "==" (EApp (EVar "buildFingerprint") (ELit LUnit)) (ELit (LString ""))) (EApp (EVar "failWith") (ELit (LString "medaka interface write: this binary carries no build fingerprint (an unstamped build), so a file it wrote could not be told from another unstamped compiler's; build with `make medaka`"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "buildInterfaceFile") (EVar "modulePath")) (EVar "targets")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EVar "e"))) (arm (PCon "Ok" (PVar "file")) () (EMatch (EApp (EApp (EVar "writeAtomically") (EApp (EVar "interfacePath") (EVar "modulePath"))) (EApp (EVar "encodeInterface") (EVar "file"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface write: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "wrote ")) (EApp (EVar "display") (EApp (EVar "interfacePath") (EVar "modulePath")))) (ELit (LString "")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "joinView" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "joinView" ((PVar "j")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "renderAtom")) (EVar "j"))))
(DTypeSig false "sectionLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "InterfaceSection") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sectionLines" ((PVar "n") (PVar "total") (PVar "s")) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "section ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " of "))) (EApp (EVar "display") (EVar "total"))) (ELit (LString "")))) (EApp (EApp (EVar "map") (ELam ((PVar "j")) (EBinOp "++" (EBinOp "++" (ELit (LString "  join ")) (EApp (EVar "display") (EApp (EVar "joinView") (EVar "j")))) (ELit (LString ""))))) (EFieldAccess (EVar "s") "isJoins"))) (EApp (EApp (EVar "map") (ELam ((PVar "row")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  row ")) (EApp (EVar "display") (EApp (EVar "fst") (EVar "row")))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppPubScheme") (EApp (EVar "snd") (EVar "row"))))) (ELit (LString ""))))) (EFieldAccess (EFieldAccess (EVar "s") "isInterface") "piCore"))))
(DTypeSig true "showLines" (TyFun (TyCon "String") (TyFun (TyCon "PreludeInterfaceFile") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "showLines" ((PVar "digest") (PVar "f")) (EBlock (DoLet false false (PVar "total") (EApp (EVar "length") (EFieldAccess (EVar "f") "ifSections"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "format ")) (EApp (EVar "display") (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikFormat"))) (ELit (LString "")))) (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "source ")) (EApp (EVar "display") (EApp (EVar "fst") (EVar "s")))) (ELit (LString " sha256 "))) (EApp (EVar "display") (EApp (EVar "snd") (EVar "s")))) (ELit (LString ""))))) (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikSources"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "compiler ")) (EApp (EVar "display") (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikCompiler"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "sections ")) (EApp (EVar "display") (EVar "total"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "digest ")) (EApp (EVar "display") (EVar "digest"))) (ELit (LString ""))))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "sectionLines") (EApp (EVar "fst") (EVar "p"))) (EVar "total")) (EApp (EVar "snd") (EVar "p"))))) (EApp (EApp (EVar "zip") (ERangeList (ELit (LInt 1)) (EVar "total") true)) (EFieldAccess (EVar "f") "ifSections")))))))
(DTypeSig false "showCmd" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "showCmd" ((PVar "path")) (EIf (EApp (EApp (EVar "S.endsWith") (ELit (LString ".mdk"))) (EVar "path")) (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface show: `")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "` is a source file; show takes the `.mdki` that `medaka interface write` wrote beside it (`"))) (EApp (EVar "display") (EApp (EVar "interfacePath") (EVar "path")))) (ELit (LString "`)")))) (EIf (EVar "otherwise") (EApp (EVar "showFile") (EVar "path")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "showFile" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "showFile" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface show: cannot read `")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "readInterface") (EVar "text")) (arm (PCon "Err" (PVar "fault")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface show: `")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EVar "display") (EApp (EVar "renderFault") (EVar "fault")))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "f") (PVar "digest"))) () (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "showLines") (EVar "digest")) (EVar "f")))))))))
(DData Public "Verdict" () ((variant "Fresh" (ConPos)) (variant "Stale" (ConPos (TyCon "String"))) (variant "Missing" (ConPos))) ())
(DTypeSig true "verdictText" (TyFun (TyCon "Verdict") (TyCon "String")))
(DFunDef false "verdictText" ((PCon "Fresh")) (ELit (LString "fresh")))
(DFunDef false "verdictText" ((PCon "Stale" (PVar "component"))) (EBinOp "++" (EBinOp "++" (ELit (LString "stale: ")) (EApp (EVar "display") (EVar "component"))) (ELit (LString ""))))
(DFunDef false "verdictText" ((PCon "Missing")) (ELit (LString "missing")))
(DTypeSig true "verdictOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Verdict"))))
(DFunDef false "verdictOf" ((PVar "modulePath")) (EMatch (EApp (EVar "readFile") (EApp (EVar "interfacePath") (EVar "modulePath"))) (arm (PCon "Err" PWild) () (EVar "Missing")) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "readInterface") (EVar "text")) (arm (PCon "Err" (PVar "fault")) () (EApp (EVar "Stale") (EApp (EVar "faultComponent") (EVar "fault")))) (arm (PCon "Ok" (PTuple (PVar "f") PWild)) () (EMatch (ETuple (EApp (EVar "readFile") (EApp (EVar "runtimePathOf") (EVar "modulePath"))) (EApp (EVar "readFile") (EVar "modulePath"))) (arm (PTuple (PCon "Ok" (PVar "runtimeSrc")) (PCon "Ok" (PVar "coreSrc"))) () (EMatch (EApp (EApp (EVar "keysMatch") (EFieldAccess (EVar "f") "ifKey")) (EApp (EApp (EVar "preludeInterfaceKey") (EApp (EVar "baseName") (EVar "modulePath"))) (EApp (EApp (EApp (EVar "inputsOf") (EVar "modulePath")) (EVar "runtimeSrc")) (EVar "coreSrc")))) (arm (PCon "None") () (EVar "Fresh")) (arm (PCon "Some" (PVar "component")) () (EApp (EVar "Stale") (EVar "component"))))) (arm PWild () (EApp (EVar "Stale") (ELit (LString "sources"))))))))))
(DTypeSig false "verifyCmd" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "verifyCmd" ((PVar "modulePath")) (EBlock (DoLet false false (PVar "verdict") (EApp (EVar "verdictOf") (EVar "modulePath"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "verdictText") (EVar "verdict")))) (DoExpr (EMatch (EVar "verdict") (arm (PCon "Fresh") () (ELit LUnit)) (arm PWild () (EApp (EVar "stageExit") (ELit (LInt 1))))))))
(DTypeSig false "printHelp" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printHelp" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "interfaceHelpText"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DTypeSig false "oneModule" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "oneModule" ((PVar "sp") (PVar "argv") (PVar "run")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "sp")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "failWith") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EIf (EApp (EApp (EVar "flag") (ELit (LString "--help"))) (EVar "a")) (EApp (EVar "printHelp") (ELit LUnit)) (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList (PVar "path")) () (EApp (EVar "run") (EVar "path"))) (arm (PList) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "usage: ")) (EApp (EVar "display") (EFieldAccess (EVar "sp") "verb"))) (ELit (LString " <path>"))))) (arm (PCons PWild (PCons (PVar "extra") PWild)) () (EApp (EVar "failWith") (EApp (EApp (EVar "unknownFlagMessage") (EVar "sp")) (EVar "extra")))))))))
(DTypeSig false "writeArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "writeSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "failWith") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EIf (EApp (EApp (EVar "flag") (ELit (LString "--help"))) (EVar "a")) (EApp (EVar "printHelp") (ELit LUnit)) (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList (PVar "path")) () (EApp (EApp (EVar "writeCmd") (EVar "path")) (EApp (EApp (EVar "flagValues") (ELit (LString "--target"))) (EVar "a")))) (arm (PList) () (EApp (EVar "failWith") (ELit (LString "usage: medaka interface write <module.mdk> [--target <profile>]...")))) (arm (PCons PWild (PCons (PVar "extra") PWild)) () (EApp (EVar "failWith") (EApp (EApp (EVar "unknownFlagMessage") (EVar "writeSpec")) (EVar "extra")))))))))
(DTypeSig true "runInterfaceCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runInterfaceCmd" ((PList)) (EApp (EVar "failWith") (ELit (LString "usage: medaka interface write|verify <module.mdk>, medaka interface show <file.mdki>"))))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "write")) (PVar "rest"))) (EApp (EVar "writeArgs") (EVar "rest")))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "show")) (PVar "rest"))) (EApp (EApp (EApp (EVar "oneModule") (EApp (EVar "plainSpec") (ELit (LString "interface show")))) (EVar "rest")) (EVar "showCmd")))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "verify")) (PVar "rest"))) (EApp (EApp (EApp (EVar "oneModule") (EApp (EVar "plainSpec") (ELit (LString "interface verify")))) (EVar "rest")) (EVar "verifyCmd")))
(DFunDef false "runInterfaceCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface: unknown subcommand '")) (EApp (EVar "display") (EVar "sub"))) (ELit (LString "' (expected: write, show, verify)")))))
# MARK
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "FlagSpec" false) (mem "spec" false) (mem "switch" false) (mem "valueList" false) (mem "withStrictDash" false) (mem "parseArgs" false) (mem "flag" false) (mem "flagValues" false) (mem "unknownFlagMessage" false))))
(DUse false (UseGroup ("io") ((mem "runCommandOk" false))))
(DUse false (UseGroup ("list") ((mem "zip" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "PreludeInputs" true) (mem "readPreludeFile" false) (mem "preludeInterfaceKey" false) (mem "faultComponent" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeFrom" false) (mem "ppDiagCliSrc" false) (mem "diagIsError" false))))
(DUse false (UseGroup ("driver" "front_gate") ((mem "cliStdlibExports" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseLocated" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "baseName" false) (mem "joinPath" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "joinWith" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("types" "interface_sexp") ((mem "PreludeInterfaceFile" true) (mem "InterfaceSection" true) (mem "encodeInterface" false) (mem "readInterface" false) (mem "renderFault" false) (mem "mergeSections" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "PreludeInterface" true) (mem "InterfaceKey" true) (mem "keysMatch" false) (mem "currentPreludeInterface" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ppPubScheme" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "lookupProfile" false) (mem "selectedProfile" false))))
(DTypeSig true "interfaceHelpText" (TyCon "String"))
(DFunDef false "interfaceHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka interface — Write, show and verify the prelude interface file\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka interface write  <module.mdk> [--target <profile>]...\n")) (ELit (LString "  medaka interface show   <file.mdki>\n")) (ELit (LString "  medaka interface verify <module.mdk>\n")) (ELit (LString "\n")) (ELit (LString "  write   type-checks the module (the prelude's core, with runtime.mdk beside\n")) (ELit (LString "          it) under each --target profile and writes <module>.mdki beside it.\n")) (ELit (LString "          Without --target the profiles are the full IO join and\n")) (ELit (LString "          wasmgc/browser-worker.  A module with a type error leaves no file.\n")) (ELit (LString "  show    prints the header and every published row.\n")) (ELit (LString "  verify  prints `fresh`, `stale: <component>` or `missing`; exit 0 only on\n")) (ELit (LString "          `fresh`.\n")) (ELit (LString "\n")) (ELit (LString "  -h, --help  prints this help.\n")))))
(DTypeSig false "writeSpec" (TyCon "ArgSpec"))
(DFunDef false "writeSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "interface write"))) (EListLit (EVar "helpSwitch") (EApp (EApp (EApp (EVar "valueList") (EListLit (ELit (LString "--target")))) (ELit (LString "PROFILE"))) (ELit (LString "a target profile whose IO join gets a section (repeatable)")))))))
(DTypeSig false "plainSpec" (TyFun (TyCon "String") (TyCon "ArgSpec")))
(DFunDef false "plainSpec" ((PVar "verb")) (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (EVar "verb")) (EListLit (EVar "helpSwitch")))))
(DTypeSig false "helpSwitch" (TyCon "FlagSpec"))
(DFunDef false "helpSwitch" () (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--help")) (ELit (LString "-h")))) (ELit (LString "print this help"))))
(DTypeSig false "inputsOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "PreludeInputs")))))
(DFunDef false "inputsOf" ((PVar "modulePath") (PVar "runtimeSrc") (PVar "coreSrc")) (ERecordCreate "PreludeInputs" ((fa "pnStdlibDir" (EApp (EVar "dirOf") (EVar "modulePath"))) (fa "pnRuntimeSrc" (EVar "runtimeSrc")) (fa "pnCoreSrc" (EVar "coreSrc")) (fa "pnCompiler" (EApp (EVar "buildFingerprint") (ELit LUnit))))))
(DTypeSig false "interfacePath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "interfacePath" ((PVar "modulePath")) (EBinOp "++" (EVar "modulePath") (ELit (LString "i"))))
(DTypeSig false "runtimePathOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "runtimePathOf" ((PVar "modulePath")) (EApp (EApp (EVar "joinPath") (EApp (EVar "dirOf") (EVar "modulePath"))) (ELit (LString "runtime.mdk"))))
(DTypeSig false "defaultTargets" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "defaultTargets" () (EListLit (ELit (LString "")) (ELit (LString "wasmgc/browser-worker"))))
(DTypeSig false "profileOfTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "TargetProfile")))))
(DFunDef false "profileOfTarget" ((PLit (LString ""))) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "profileOfTarget" ((PVar "name")) (EApp (EApp (EMethodRef "map") (EVar "Some")) (EApp (EVar "lookupProfile") (EVar "name"))))
(DTypeSig false "driveUnder" (TyFun (TyCon "PreludeInputs") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "TargetProfile")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "PreludeInterface")))))))))
(DFunDef false "driveUnder" ((PVar "inputs") (PVar "modulePath") (PVar "profile")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "selectedProfile"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "profile"))) (DoLet false false (PVar "exports") (EApp (EVar "cliStdlibExports") (EFieldAccess (EVar "inputs") "pnStdlibDir"))) (DoLet false false (PVar "runtimeSrc") (EFieldAccess (EVar "inputs") "pnRuntimeSrc")) (DoLet false false (PVar "coreSrc") (EFieldAccess (EVar "inputs") "pnCoreSrc")) (DoLet false false (PVar "errors") (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "exports")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (EVar "coreSrc"))))) (DoLet false false (PVar "trivial") (EMatch (EVar "errors") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "exports")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (ELit (LString "x = 1\n"))))) (arm PWild () (EListLit)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "saved"))) (DoExpr (EMatch (ETuple (EVar "errors") (EApp (EMethodRef "length") (EVar "trivial"))) (arm (PTuple (PList) PWild) () (EMatch (EApp (EVar "currentPreludeInterface") (ELit LUnit)) (arm (PList) () (EApp (EVar "Err") (ELit (LString "medaka interface write: the check left no prelude interface")))) (arm (PVar "sections") () (EApp (EVar "Ok") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "s")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "j")) (ETuple (EVar "j") (EApp (EVar "snd") (EVar "s"))))) (EApp (EVar "fst") (EVar "s"))))) (EVar "sections")))))) (arm PWild () (EApp (EVar "Err") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "coreSrc")) (EVar "modulePath"))) (EVar "errors")))))))))
(DTypeSig true "buildInterfaceFile" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PreludeInterfaceFile"))))))
(DFunDef false "buildInterfaceFile" ((PVar "modulePath") (PVar "targets")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readPreludeFile") (EApp (EVar "runtimePathOf") (EVar "modulePath")))) (ELam ((PVar "runtimeSrc")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readPreludeFile") (EVar "modulePath"))) (ELam ((PVar "coreSrc")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EMethodRef "traverse") (EVar "profileOfTarget")) (EIf (EApp (EMethodRef "isEmpty") (EVar "targets")) (EVar "defaultTargets") (EVar "targets")))) (ELam ((PVar "profiles")) (ELet false (PVar "inputs") (EApp (EApp (EApp (EVar "inputsOf") (EVar "modulePath")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EMethodRef "traverse") (EApp (EApp (EVar "driveUnder") (EVar "inputs")) (EVar "modulePath"))) (EVar "profiles"))) (ELam ((PVar "drives")) (EApp (EVar "Ok") (ERecordCreate "PreludeInterfaceFile" ((fa "ifKey" (EApp (EApp (EVar "preludeInterfaceKey") (EApp (EVar "baseName") (EVar "modulePath"))) (EVar "inputs"))) (fa "ifSections" (EApp (EVar "mergeSections") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "d")) (EVar "d"))) (EVar "drives")))))))))))))))))
(DTypeSig false "writeAtomically" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "writeAtomically" ((PVar "path") (PVar "text")) (EMatch (EApp (EApp (EVar "runCommandOk") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ".new.XXXXXX"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot make a staging directory beside `")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "dir") (EApp (EVar "S.trim") (EVar "out"))) (DoLet false false (PVar "staging") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EApp (EVar "baseName") (EVar "path")))) (DoLet false false (PVar "result") (EMatch (EApp (EApp (EVar "writeFile") (EVar "staging")) (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot write `")) (EApp (EMethodRef "display") (EVar "staging"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "rename") (EVar "staging")) (EVar "path")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot move `")) (EApp (EMethodRef "display") (EVar "staging"))) (ELit (LString "` to `"))) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))))))) (DoLet false false PWild (EApp (EVar "removeFile") (EVar "staging"))) (DoLet false false PWild (EApp (EVar "removeDir") (EVar "dir"))) (DoExpr (EVar "result"))))))
(DTypeSig false "failWith" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "failWith" ((PVar "msg")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))
(DTypeSig false "writeCmd" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeCmd" ((PVar "modulePath") (PVar "targets")) (EIf (EBinOp "==" (EApp (EVar "buildFingerprint") (ELit LUnit)) (ELit (LString ""))) (EApp (EVar "failWith") (ELit (LString "medaka interface write: this binary carries no build fingerprint (an unstamped build), so a file it wrote could not be told from another unstamped compiler's; build with `make medaka`"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "buildInterfaceFile") (EVar "modulePath")) (EVar "targets")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EVar "e"))) (arm (PCon "Ok" (PVar "file")) () (EMatch (EApp (EApp (EVar "writeAtomically") (EApp (EVar "interfacePath") (EVar "modulePath"))) (EApp (EVar "encodeInterface") (EVar "file"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface write: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "wrote ")) (EApp (EMethodRef "display") (EApp (EVar "interfacePath") (EVar "modulePath")))) (ELit (LString "")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "joinView" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "joinView" ((PVar "j")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "renderAtom")) (EVar "j"))))
(DTypeSig false "sectionLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "InterfaceSection") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sectionLines" ((PVar "n") (PVar "total") (PVar "s")) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "section ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EVar "total"))) (ELit (LString "")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "j")) (EBinOp "++" (EBinOp "++" (ELit (LString "  join ")) (EApp (EMethodRef "display") (EApp (EVar "joinView") (EVar "j")))) (ELit (LString ""))))) (EFieldAccess (EVar "s") "isJoins"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  row ")) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "row")))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppPubScheme") (EApp (EVar "snd") (EVar "row"))))) (ELit (LString ""))))) (EFieldAccess (EFieldAccess (EVar "s") "isInterface") "piCore"))))
(DTypeSig true "showLines" (TyFun (TyCon "String") (TyFun (TyCon "PreludeInterfaceFile") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "showLines" ((PVar "digest") (PVar "f")) (EBlock (DoLet false false (PVar "total") (EApp (EMethodRef "length") (EFieldAccess (EVar "f") "ifSections"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "format ")) (EApp (EMethodRef "display") (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikFormat"))) (ELit (LString "")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "source ")) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "s")))) (ELit (LString " sha256 "))) (EApp (EMethodRef "display") (EApp (EVar "snd") (EVar "s")))) (ELit (LString ""))))) (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikSources"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "compiler ")) (EApp (EMethodRef "display") (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikCompiler"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "sections ")) (EApp (EMethodRef "display") (EVar "total"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "digest ")) (EApp (EMethodRef "display") (EVar "digest"))) (ELit (LString ""))))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "sectionLines") (EApp (EVar "fst") (EVar "p"))) (EVar "total")) (EApp (EVar "snd") (EVar "p"))))) (EApp (EApp (EVar "zip") (ERangeList (ELit (LInt 1)) (EVar "total") true)) (EFieldAccess (EVar "f") "ifSections")))))))
(DTypeSig false "showCmd" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "showCmd" ((PVar "path")) (EIf (EApp (EApp (EVar "S.endsWith") (ELit (LString ".mdk"))) (EVar "path")) (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface show: `")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "` is a source file; show takes the `.mdki` that `medaka interface write` wrote beside it (`"))) (EApp (EMethodRef "display") (EApp (EVar "interfacePath") (EVar "path")))) (ELit (LString "`)")))) (EIf (EVar "otherwise") (EApp (EVar "showFile") (EVar "path")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "showFile" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "showFile" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface show: cannot read `")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "readInterface") (EVar "text")) (arm (PCon "Err" (PVar "fault")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface show: `")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EApp (EVar "renderFault") (EVar "fault")))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "f") (PVar "digest"))) () (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "showLines") (EVar "digest")) (EVar "f")))))))))
(DData Public "Verdict" () ((variant "Fresh" (ConPos)) (variant "Stale" (ConPos (TyCon "String"))) (variant "Missing" (ConPos))) ())
(DTypeSig true "verdictText" (TyFun (TyCon "Verdict") (TyCon "String")))
(DFunDef false "verdictText" ((PCon "Fresh")) (ELit (LString "fresh")))
(DFunDef false "verdictText" ((PCon "Stale" (PVar "component"))) (EBinOp "++" (EBinOp "++" (ELit (LString "stale: ")) (EApp (EMethodRef "display") (EVar "component"))) (ELit (LString ""))))
(DFunDef false "verdictText" ((PCon "Missing")) (ELit (LString "missing")))
(DTypeSig true "verdictOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Verdict"))))
(DFunDef false "verdictOf" ((PVar "modulePath")) (EMatch (EApp (EVar "readFile") (EApp (EVar "interfacePath") (EVar "modulePath"))) (arm (PCon "Err" PWild) () (EVar "Missing")) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "readInterface") (EVar "text")) (arm (PCon "Err" (PVar "fault")) () (EApp (EVar "Stale") (EApp (EVar "faultComponent") (EVar "fault")))) (arm (PCon "Ok" (PTuple (PVar "f") PWild)) () (EMatch (ETuple (EApp (EVar "readFile") (EApp (EVar "runtimePathOf") (EVar "modulePath"))) (EApp (EVar "readFile") (EVar "modulePath"))) (arm (PTuple (PCon "Ok" (PVar "runtimeSrc")) (PCon "Ok" (PVar "coreSrc"))) () (EMatch (EApp (EApp (EVar "keysMatch") (EFieldAccess (EVar "f") "ifKey")) (EApp (EApp (EVar "preludeInterfaceKey") (EApp (EVar "baseName") (EVar "modulePath"))) (EApp (EApp (EApp (EVar "inputsOf") (EVar "modulePath")) (EVar "runtimeSrc")) (EVar "coreSrc")))) (arm (PCon "None") () (EVar "Fresh")) (arm (PCon "Some" (PVar "component")) () (EApp (EVar "Stale") (EVar "component"))))) (arm PWild () (EApp (EVar "Stale") (ELit (LString "sources"))))))))))
(DTypeSig false "verifyCmd" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "verifyCmd" ((PVar "modulePath")) (EBlock (DoLet false false (PVar "verdict") (EApp (EVar "verdictOf") (EVar "modulePath"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "verdictText") (EVar "verdict")))) (DoExpr (EMatch (EVar "verdict") (arm (PCon "Fresh") () (ELit LUnit)) (arm PWild () (EApp (EVar "stageExit") (ELit (LInt 1))))))))
(DTypeSig false "printHelp" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printHelp" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "interfaceHelpText"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DTypeSig false "oneModule" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "oneModule" ((PVar "sp") (PVar "argv") (PVar "run")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "sp")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "failWith") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EIf (EApp (EApp (EVar "flag") (ELit (LString "--help"))) (EVar "a")) (EApp (EVar "printHelp") (ELit LUnit)) (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList (PVar "path")) () (EApp (EVar "run") (EVar "path"))) (arm (PList) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "usage: ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sp") "verb"))) (ELit (LString " <path>"))))) (arm (PCons PWild (PCons (PVar "extra") PWild)) () (EApp (EVar "failWith") (EApp (EApp (EVar "unknownFlagMessage") (EVar "sp")) (EVar "extra")))))))))
(DTypeSig false "writeArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "writeSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "failWith") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EIf (EApp (EApp (EVar "flag") (ELit (LString "--help"))) (EVar "a")) (EApp (EVar "printHelp") (ELit LUnit)) (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList (PVar "path")) () (EApp (EApp (EVar "writeCmd") (EVar "path")) (EApp (EApp (EVar "flagValues") (ELit (LString "--target"))) (EVar "a")))) (arm (PList) () (EApp (EVar "failWith") (ELit (LString "usage: medaka interface write <module.mdk> [--target <profile>]...")))) (arm (PCons PWild (PCons (PVar "extra") PWild)) () (EApp (EVar "failWith") (EApp (EApp (EVar "unknownFlagMessage") (EVar "writeSpec")) (EVar "extra")))))))))
(DTypeSig true "runInterfaceCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runInterfaceCmd" ((PList)) (EApp (EVar "failWith") (ELit (LString "usage: medaka interface write|verify <module.mdk>, medaka interface show <file.mdki>"))))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "write")) (PVar "rest"))) (EApp (EVar "writeArgs") (EVar "rest")))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "show")) (PVar "rest"))) (EApp (EApp (EApp (EVar "oneModule") (EApp (EVar "plainSpec") (ELit (LString "interface show")))) (EVar "rest")) (EVar "showCmd")))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "verify")) (PVar "rest"))) (EApp (EApp (EApp (EVar "oneModule") (EApp (EVar "plainSpec") (ELit (LString "interface verify")))) (EVar "rest")) (EVar "verifyCmd")))
(DFunDef false "runInterfaceCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface: unknown subcommand '")) (EApp (EMethodRef "display") (EMethodRef "sub"))) (ELit (LString "' (expected: write, show, verify)")))))
