# META
source_lines=329
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
  ArgSpec, spec, valueList, withStrictDash, parseArgs, flagValues,
  unknownFlagMessage
}
import bytes.{encodeUtf8}
import crypto.sha256.{sha256}
import hex as Hex
import list.{zip}
import string as S
import driver.build_cmd.{readPreludeFile}
import driver.diagnostics.{analyzeFrom, ppDiagCliSrc, diagIsError}
import driver.front_gate.{cliStdlibExports}
import frontend.parser.{parseLocated}
import support.path.{dirOf, baseName, joinPath}
import support.stage_count.{stageExit}
import support.util.{joinNl, joinWith}
import types.effect_rows.{Atom, renderAtom}
import types.interface_sexp.{
  PreludeInterfaceFile(..), InterfaceSection(..), formatVersion,
  encodeInterface, decodeInterface, mergeSections
}
import types.prelude_interface.{
  PreludeInterface(..), InterfaceKey(..), interfaceKeyOf, keysMatch,
  currentPreludeInterface
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
]

writeSpec : ArgSpec
writeSpec =
  withStrictDash
    (spec "interface write" [
      valueList
        ["--target"]
        "PROFILE"
        "a target profile whose IO join gets a section (repeatable)",
    ])

plainSpec : String -> ArgSpec
plainSpec verb = withStrictDash (spec verb [])

-- ── the key ─────────────────────────────────────────────────────────────────

sha256Of : String -> String
sha256Of text = Hex.encode (sha256 (encodeUtf8 text))

-- The key a module is written under: the two prelude sources by their path
-- relative to the stdlib directory, hashed, and the compiler that checked them.
keyOfSources : String -> String -> String -> InterfaceKey
keyOfSources coreName runtimeSrc coreSrc =
  interfaceKeyOf
    formatVersion
    [("runtime.mdk", sha256Of runtimeSrc), (coreName, sha256Of coreSrc)]
    (buildFingerprint ())

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
driveUnder : String ->
  String ->
  String ->
  String ->
  Option TargetProfile ->
  <IO> Result String (List (List Atom, PreludeInterface))
driveUnder stdlibDir modulePath runtimeSrc coreSrc profile =
  let saved = !selectedProfile
  selectedProfile := profile
  let exports = cliStdlibExports stdlibDir
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

-- Every profile's drives, or the first profile's error.
driveAll : String ->
  String ->
  String ->
  String ->
  List (Option TargetProfile) ->
  <IO> Result String (List (List Atom, PreludeInterface))
driveAll _ _ _ _ [] = Ok []
driveAll stdlibDir modulePath runtimeSrc coreSrc (p :: rest) =
  match driveUnder stdlibDir modulePath runtimeSrc coreSrc p
    Err e => Err e
    Ok here =>
      map (here ++ _) (driveAll stdlibDir modulePath runtimeSrc coreSrc rest)

-- The file for [modulePath] checked under [targets] (profile names, "" for the
-- full join; none given means the default targets).
export
buildInterfaceFile : String ->
  List String ->
  <IO> Result String PreludeInterfaceFile
buildInterfaceFile modulePath targets = do
  runtimeSrc <- readPreludeFile (runtimePathOf modulePath)
  coreSrc <- readPreludeFile modulePath
  profiles <- resultList
    (map profileOfTarget (if isEmpty targets then defaultTargets else targets))
  let drive = driveAll (dirOf modulePath) modulePath runtimeSrc coreSrc
  drives <- drive profiles
  Ok PreludeInterfaceFile {
    ifKey = keyOfSources (baseName modulePath) runtimeSrc coreSrc,
    ifSections = mergeSections drives,
  }

resultList : List (Result String a) -> Result String (List a)
resultList [] = Ok []
resultList (r :: rest) = match r
  Err e => Err e
  Ok x => map (x :: _) (resultList rest)

-- The text goes to a sibling file first and is renamed over the target, so a
-- reader never sees a half-written file.  The sibling's name carries the text's
-- own digest: a concurrent writer of the same module writes the same bytes.
writeAtomically : String -> String -> <IO> Result String Unit
writeAtomically path text =
  let staging = "\{path}.new.\{S.take 16 (sha256Of text)}"
  match writeFile staging text
    Err e => Err "cannot write `\{staging}`: \{e}"
    Ok _ => match rename staging path
      Ok _ => Ok ()
      Err e =>
        let _ = removeFile staging
        Err "cannot move `\{staging}` to `\{path}`: \{e}"

failWith : String -> <IO> Unit
-- The same two lines as `entries/entry_support.mdk`'s `failWith`; a tool cannot import an entry.
-- lint-disable-next-line rule-duplicate-body
failWith msg =
  let _ = ePutStrLn msg
  stageExit 1

writeCmd : String -> List String -> <IO> Unit
writeCmd modulePath targets = match buildInterfaceFile modulePath targets
  Err e => failWith e
  Ok file =>
    match writeAtomically (interfacePath modulePath) (encodeInterface file)
      Err e => failWith "medaka interface write: \{e}"
      Ok _ => putStrLn "wrote \{interfacePath modulePath}"

-- ── show ────────────────────────────────────────────────────────────────────

joinView : List Atom -> String
joinView j = joinWith "," (map renderAtom j)

-- The digest the header carries, read off the file's first line.
digestOfText : String -> String
digestOfText text = match S.indexOf "(digest " text
  None => "?"
  Some i =>
    let tail = S.drop (i + 8) text
    match S.indexOf ")" tail
      Some j => S.take j tail
      None => "?"

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
showCmd path = match readFile path
  Err e => failWith "medaka interface show: cannot read `\{path}`: \{e}"
  Ok text => match decodeInterface text
    Err e =>
      failWith "medaka interface show: `\{path}`: \{e.sePath}: \{e.seWhat}"
    Ok f => putStrLn (joinNl (showLines (digestOfText text) f))

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
  Ok text => match decodeInterface text
    Err e =>
      Stale (if S.contains "format version" e.seWhat then "format" else "file")
    Ok f => match (readFile (runtimePathOf modulePath), readFile modulePath)
      (Ok runtimeSrc, Ok coreSrc) =>
        match (keysMatch
          f.ifKey
          (keyOfSources (baseName modulePath) runtimeSrc coreSrc))
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

wantsHelp : List String -> Bool
wantsHelp ("--help" :: _) = True
wantsHelp ("-h" :: _) = True
wantsHelp _ = False

printHelp : Unit -> <IO> Unit
printHelp _ =
  let _ = putStrLn interfaceHelpText
  stageExit 0

oneModule : ArgSpec -> List String -> (String -> <IO> Unit) -> <IO> Unit
oneModule sp argv run = match parseArgs sp argv
  Err m => failWith m
  Ok a => match a.positionals
    [path] => run path
    [] => failWith "usage: \{sp.verb} <path>"
    _ :: extra :: _ => failWith (unknownFlagMessage sp extra)

writeArgs : List String -> <IO> Unit
writeArgs argv = match parseArgs writeSpec argv
  Err m => failWith m
  Ok a => match a.positionals
    [path] => writeCmd path (flagValues "--target" a)
    [] =>
      failWith
        "usage: medaka interface write <module.mdk> [--target <profile>]..."
    _ :: extra :: _ => failWith (unknownFlagMessage writeSpec extra)

{- | `medaka interface <write|show|verify> …`. -}
export
runInterfaceCmd : List String -> <IO> Unit
runInterfaceCmd [] =
  failWith "usage: medaka interface <write|show|verify> <module.mdk>"
runInterfaceCmd ("write" :: rest) =
  if wantsHelp rest then printHelp () else writeArgs rest
runInterfaceCmd ("show" :: rest) =
  if wantsHelp rest then
    printHelp ()
  else
    oneModule (plainSpec "interface show") rest showCmd
runInterfaceCmd ("verify" :: rest) =
  if wantsHelp rest then
    printHelp ()
  else
    oneModule (plainSpec "interface verify") rest verifyCmd
runInterfaceCmd (sub :: _) =
  failWith
    "medaka interface: unknown subcommand '\{sub}' (expected: write, show, verify)"
# DESUGAR
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "spec" false) (mem "valueList" false) (mem "withStrictDash" false) (mem "parseArgs" false) (mem "flagValues" false) (mem "unknownFlagMessage" false))))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false))))
(DUse false (UseGroup ("crypto" "sha256") ((mem "sha256" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DUse false (UseGroup ("list") ((mem "zip" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "readPreludeFile" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeFrom" false) (mem "ppDiagCliSrc" false) (mem "diagIsError" false))))
(DUse false (UseGroup ("driver" "front_gate") ((mem "cliStdlibExports" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseLocated" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "baseName" false) (mem "joinPath" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "joinWith" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("types" "interface_sexp") ((mem "PreludeInterfaceFile" true) (mem "InterfaceSection" true) (mem "formatVersion" false) (mem "encodeInterface" false) (mem "decodeInterface" false) (mem "mergeSections" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "PreludeInterface" true) (mem "InterfaceKey" true) (mem "interfaceKeyOf" false) (mem "keysMatch" false) (mem "currentPreludeInterface" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ppPubScheme" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "lookupProfile" false) (mem "selectedProfile" false))))
(DTypeSig true "interfaceHelpText" (TyCon "String"))
(DFunDef false "interfaceHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka interface — Write, show and verify the prelude interface file\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka interface write  <module.mdk> [--target <profile>]...\n")) (ELit (LString "  medaka interface show   <file.mdki>\n")) (ELit (LString "  medaka interface verify <module.mdk>\n")) (ELit (LString "\n")) (ELit (LString "  write   type-checks the module (the prelude's core, with runtime.mdk beside\n")) (ELit (LString "          it) under each --target profile and writes <module>.mdki beside it.\n")) (ELit (LString "          Without --target the profiles are the full IO join and\n")) (ELit (LString "          wasmgc/browser-worker.  A module with a type error leaves no file.\n")) (ELit (LString "  show    prints the header and every published row.\n")) (ELit (LString "  verify  prints `fresh`, `stale: <component>` or `missing`; exit 0 only on\n")) (ELit (LString "          `fresh`.\n")))))
(DTypeSig false "writeSpec" (TyCon "ArgSpec"))
(DFunDef false "writeSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "interface write"))) (EListLit (EApp (EApp (EApp (EVar "valueList") (EListLit (ELit (LString "--target")))) (ELit (LString "PROFILE"))) (ELit (LString "a target profile whose IO join gets a section (repeatable)")))))))
(DTypeSig false "plainSpec" (TyFun (TyCon "String") (TyCon "ArgSpec")))
(DFunDef false "plainSpec" ((PVar "verb")) (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (EVar "verb")) (EListLit))))
(DTypeSig false "sha256Of" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sha256Of" ((PVar "text")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256") (EApp (EVar "encodeUtf8") (EVar "text")))))
(DTypeSig false "keyOfSources" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "InterfaceKey")))))
(DFunDef false "keyOfSources" ((PVar "coreName") (PVar "runtimeSrc") (PVar "coreSrc")) (EApp (EApp (EApp (EVar "interfaceKeyOf") (EVar "formatVersion")) (EListLit (ETuple (ELit (LString "runtime.mdk")) (EApp (EVar "sha256Of") (EVar "runtimeSrc"))) (ETuple (EVar "coreName") (EApp (EVar "sha256Of") (EVar "coreSrc"))))) (EApp (EVar "buildFingerprint") (ELit LUnit))))
(DTypeSig false "interfacePath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "interfacePath" ((PVar "modulePath")) (EBinOp "++" (EVar "modulePath") (ELit (LString "i"))))
(DTypeSig false "runtimePathOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "runtimePathOf" ((PVar "modulePath")) (EApp (EApp (EVar "joinPath") (EApp (EVar "dirOf") (EVar "modulePath"))) (ELit (LString "runtime.mdk"))))
(DTypeSig false "defaultTargets" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "defaultTargets" () (EListLit (ELit (LString "")) (ELit (LString "wasmgc/browser-worker"))))
(DTypeSig false "profileOfTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "TargetProfile")))))
(DFunDef false "profileOfTarget" ((PLit (LString ""))) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "profileOfTarget" ((PVar "name")) (EApp (EApp (EVar "map") (EVar "Some")) (EApp (EVar "lookupProfile") (EVar "name"))))
(DTypeSig false "driveUnder" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "TargetProfile")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "PreludeInterface")))))))))))
(DFunDef false "driveUnder" ((PVar "stdlibDir") (PVar "modulePath") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "profile")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "selectedProfile"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "profile"))) (DoLet false false (PVar "exports") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (DoLet false false (PVar "errors") (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "exports")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (EVar "coreSrc"))))) (DoLet false false (PVar "trivial") (EMatch (EVar "errors") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "exports")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (ELit (LString "x = 1\n"))))) (arm PWild () (EListLit)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "saved"))) (DoExpr (EMatch (ETuple (EVar "errors") (EApp (EVar "length") (EVar "trivial"))) (arm (PTuple (PList) PWild) () (EMatch (EApp (EVar "currentPreludeInterface") (ELit LUnit)) (arm (PList) () (EApp (EVar "Err") (ELit (LString "medaka interface write: the check left no prelude interface")))) (arm (PVar "sections") () (EApp (EVar "Ok") (EApp (EApp (EVar "flatMap") (ELam ((PVar "s")) (EApp (EApp (EVar "map") (ELam ((PVar "j")) (ETuple (EVar "j") (EApp (EVar "snd") (EVar "s"))))) (EApp (EVar "fst") (EVar "s"))))) (EVar "sections")))))) (arm PWild () (EApp (EVar "Err") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "coreSrc")) (EVar "modulePath"))) (EVar "errors")))))))))
(DTypeSig false "driveAll" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "TargetProfile"))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "PreludeInterface")))))))))))
(DFunDef false "driveAll" (PWild PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "driveAll" ((PVar "stdlibDir") (PVar "modulePath") (PVar "runtimeSrc") (PVar "coreSrc") (PCons (PVar "p") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "driveUnder") (EVar "stdlibDir")) (EVar "modulePath")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "here")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "here") (EVar "_s")))) (EApp (EApp (EApp (EApp (EApp (EVar "driveAll") (EVar "stdlibDir")) (EVar "modulePath")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "rest"))))))
(DTypeSig true "buildInterfaceFile" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PreludeInterfaceFile"))))))
(DFunDef false "buildInterfaceFile" ((PVar "modulePath") (PVar "targets")) (EApp (EApp (EVar "andThen") (EApp (EVar "readPreludeFile") (EApp (EVar "runtimePathOf") (EVar "modulePath")))) (ELam ((PVar "runtimeSrc")) (EApp (EApp (EVar "andThen") (EApp (EVar "readPreludeFile") (EVar "modulePath"))) (ELam ((PVar "coreSrc")) (EApp (EApp (EVar "andThen") (EApp (EVar "resultList") (EApp (EApp (EVar "map") (EVar "profileOfTarget")) (EIf (EApp (EVar "isEmpty") (EVar "targets")) (EVar "defaultTargets") (EVar "targets"))))) (ELam ((PVar "profiles")) (ELet false (PVar "drive") (EApp (EApp (EApp (EApp (EVar "driveAll") (EApp (EVar "dirOf") (EVar "modulePath"))) (EVar "modulePath")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EVar "andThen") (EApp (EVar "drive") (EVar "profiles"))) (ELam ((PVar "drives")) (EApp (EVar "Ok") (ERecordCreate "PreludeInterfaceFile" ((fa "ifKey" (EApp (EApp (EApp (EVar "keyOfSources") (EApp (EVar "baseName") (EVar "modulePath"))) (EVar "runtimeSrc")) (EVar "coreSrc"))) (fa "ifSections" (EApp (EVar "mergeSections") (EVar "drives"))))))))))))))))
(DTypeSig false "resultList" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "resultList" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "resultList" ((PCons (PVar "r") (PVar "rest"))) (EMatch (EVar "r") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "x")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "resultList") (EVar "rest"))))))
(DTypeSig false "writeAtomically" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "writeAtomically" ((PVar "path") (PVar "text")) (EBlock (DoLet false false (PVar "staging") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ".new."))) (EApp (EVar "display") (EApp (EApp (EVar "S.take") (ELit (LInt 16))) (EApp (EVar "sha256Of") (EVar "text"))))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "staging")) (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot write `")) (EApp (EVar "display") (EVar "staging"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "rename") (EVar "staging")) (EVar "path")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EVar "staging"))) (DoExpr (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot move `")) (EApp (EVar "display") (EVar "staging"))) (ELit (LString "` to `"))) (EApp (EVar "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))))))))))))
(DTypeSig false "failWith" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "failWith" ((PVar "msg")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))
(DTypeSig false "writeCmd" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeCmd" ((PVar "modulePath") (PVar "targets")) (EMatch (EApp (EApp (EVar "buildInterfaceFile") (EVar "modulePath")) (EVar "targets")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EVar "e"))) (arm (PCon "Ok" (PVar "file")) () (EMatch (EApp (EApp (EVar "writeAtomically") (EApp (EVar "interfacePath") (EVar "modulePath"))) (EApp (EVar "encodeInterface") (EVar "file"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface write: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "wrote ")) (EApp (EVar "display") (EApp (EVar "interfacePath") (EVar "modulePath")))) (ELit (LString "")))))))))
(DTypeSig false "joinView" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "joinView" ((PVar "j")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "renderAtom")) (EVar "j"))))
(DTypeSig false "digestOfText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "digestOfText" ((PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "(digest "))) (EVar "text")) (arm (PCon "None") () (ELit (LString "?"))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "tail") (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 8)))) (EVar "text"))) (DoExpr (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString ")"))) (EVar "tail")) (arm (PCon "Some" (PVar "j")) () (EApp (EApp (EVar "S.take") (EVar "j")) (EVar "tail"))) (arm (PCon "None") () (ELit (LString "?")))))))))
(DTypeSig false "sectionLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "InterfaceSection") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sectionLines" ((PVar "n") (PVar "total") (PVar "s")) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "section ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " of "))) (EApp (EVar "display") (EVar "total"))) (ELit (LString "")))) (EApp (EApp (EVar "map") (ELam ((PVar "j")) (EBinOp "++" (EBinOp "++" (ELit (LString "  join ")) (EApp (EVar "display") (EApp (EVar "joinView") (EVar "j")))) (ELit (LString ""))))) (EFieldAccess (EVar "s") "isJoins"))) (EApp (EApp (EVar "map") (ELam ((PVar "row")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  row ")) (EApp (EVar "display") (EApp (EVar "fst") (EVar "row")))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppPubScheme") (EApp (EVar "snd") (EVar "row"))))) (ELit (LString ""))))) (EFieldAccess (EFieldAccess (EVar "s") "isInterface") "piCore"))))
(DTypeSig true "showLines" (TyFun (TyCon "String") (TyFun (TyCon "PreludeInterfaceFile") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "showLines" ((PVar "digest") (PVar "f")) (EBlock (DoLet false false (PVar "total") (EApp (EVar "length") (EFieldAccess (EVar "f") "ifSections"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "format ")) (EApp (EVar "display") (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikFormat"))) (ELit (LString "")))) (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "source ")) (EApp (EVar "display") (EApp (EVar "fst") (EVar "s")))) (ELit (LString " sha256 "))) (EApp (EVar "display") (EApp (EVar "snd") (EVar "s")))) (ELit (LString ""))))) (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikSources"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "compiler ")) (EApp (EVar "display") (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikCompiler"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "sections ")) (EApp (EVar "display") (EVar "total"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "digest ")) (EApp (EVar "display") (EVar "digest"))) (ELit (LString ""))))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "sectionLines") (EApp (EVar "fst") (EVar "p"))) (EVar "total")) (EApp (EVar "snd") (EVar "p"))))) (EApp (EApp (EVar "zip") (ERangeList (ELit (LInt 1)) (EVar "total") true)) (EFieldAccess (EVar "f") "ifSections")))))))
(DTypeSig false "showCmd" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "showCmd" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface show: cannot read `")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "decodeInterface") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface show: `")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EVar "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString ": "))) (EApp (EVar "display") (EFieldAccess (EVar "e") "seWhat"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "f")) () (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "showLines") (EApp (EVar "digestOfText") (EVar "text"))) (EVar "f")))))))))
(DData Public "Verdict" () ((variant "Fresh" (ConPos)) (variant "Stale" (ConPos (TyCon "String"))) (variant "Missing" (ConPos))) ())
(DTypeSig true "verdictText" (TyFun (TyCon "Verdict") (TyCon "String")))
(DFunDef false "verdictText" ((PCon "Fresh")) (ELit (LString "fresh")))
(DFunDef false "verdictText" ((PCon "Stale" (PVar "component"))) (EBinOp "++" (EBinOp "++" (ELit (LString "stale: ")) (EApp (EVar "display") (EVar "component"))) (ELit (LString ""))))
(DFunDef false "verdictText" ((PCon "Missing")) (ELit (LString "missing")))
(DTypeSig true "verdictOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Verdict"))))
(DFunDef false "verdictOf" ((PVar "modulePath")) (EMatch (EApp (EVar "readFile") (EApp (EVar "interfacePath") (EVar "modulePath"))) (arm (PCon "Err" PWild) () (EVar "Missing")) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "decodeInterface") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Stale") (EIf (EApp (EApp (EVar "S.contains") (ELit (LString "format version"))) (EFieldAccess (EVar "e") "seWhat")) (ELit (LString "format")) (ELit (LString "file"))))) (arm (PCon "Ok" (PVar "f")) () (EMatch (ETuple (EApp (EVar "readFile") (EApp (EVar "runtimePathOf") (EVar "modulePath"))) (EApp (EVar "readFile") (EVar "modulePath"))) (arm (PTuple (PCon "Ok" (PVar "runtimeSrc")) (PCon "Ok" (PVar "coreSrc"))) () (EMatch (EApp (EApp (EVar "keysMatch") (EFieldAccess (EVar "f") "ifKey")) (EApp (EApp (EApp (EVar "keyOfSources") (EApp (EVar "baseName") (EVar "modulePath"))) (EVar "runtimeSrc")) (EVar "coreSrc"))) (arm (PCon "None") () (EVar "Fresh")) (arm (PCon "Some" (PVar "component")) () (EApp (EVar "Stale") (EVar "component"))))) (arm PWild () (EApp (EVar "Stale") (ELit (LString "sources"))))))))))
(DTypeSig false "verifyCmd" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "verifyCmd" ((PVar "modulePath")) (EBlock (DoLet false false (PVar "verdict") (EApp (EVar "verdictOf") (EVar "modulePath"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "verdictText") (EVar "verdict")))) (DoExpr (EMatch (EVar "verdict") (arm (PCon "Fresh") () (ELit LUnit)) (arm PWild () (EApp (EVar "stageExit") (ELit (LInt 1))))))))
(DTypeSig false "wantsHelp" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "wantsHelp" ((PCons (PLit (LString "--help")) PWild)) (EVar "True"))
(DFunDef false "wantsHelp" ((PCons (PLit (LString "-h")) PWild)) (EVar "True"))
(DFunDef false "wantsHelp" (PWild) (EVar "False"))
(DTypeSig false "printHelp" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printHelp" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "interfaceHelpText"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DTypeSig false "oneModule" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "oneModule" ((PVar "sp") (PVar "argv") (PVar "run")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "sp")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "failWith") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList (PVar "path")) () (EApp (EVar "run") (EVar "path"))) (arm (PList) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "usage: ")) (EApp (EVar "display") (EFieldAccess (EVar "sp") "verb"))) (ELit (LString " <path>"))))) (arm (PCons PWild (PCons (PVar "extra") PWild)) () (EApp (EVar "failWith") (EApp (EApp (EVar "unknownFlagMessage") (EVar "sp")) (EVar "extra"))))))))
(DTypeSig false "writeArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "writeSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "failWith") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList (PVar "path")) () (EApp (EApp (EVar "writeCmd") (EVar "path")) (EApp (EApp (EVar "flagValues") (ELit (LString "--target"))) (EVar "a")))) (arm (PList) () (EApp (EVar "failWith") (ELit (LString "usage: medaka interface write <module.mdk> [--target <profile>]...")))) (arm (PCons PWild (PCons (PVar "extra") PWild)) () (EApp (EVar "failWith") (EApp (EApp (EVar "unknownFlagMessage") (EVar "writeSpec")) (EVar "extra"))))))))
(DTypeSig true "runInterfaceCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runInterfaceCmd" ((PList)) (EApp (EVar "failWith") (ELit (LString "usage: medaka interface <write|show|verify> <module.mdk>"))))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "write")) (PVar "rest"))) (EIf (EApp (EVar "wantsHelp") (EVar "rest")) (EApp (EVar "printHelp") (ELit LUnit)) (EApp (EVar "writeArgs") (EVar "rest"))))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "show")) (PVar "rest"))) (EIf (EApp (EVar "wantsHelp") (EVar "rest")) (EApp (EVar "printHelp") (ELit LUnit)) (EApp (EApp (EApp (EVar "oneModule") (EApp (EVar "plainSpec") (ELit (LString "interface show")))) (EVar "rest")) (EVar "showCmd"))))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "verify")) (PVar "rest"))) (EIf (EApp (EVar "wantsHelp") (EVar "rest")) (EApp (EVar "printHelp") (ELit LUnit)) (EApp (EApp (EApp (EVar "oneModule") (EApp (EVar "plainSpec") (ELit (LString "interface verify")))) (EVar "rest")) (EVar "verifyCmd"))))
(DFunDef false "runInterfaceCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface: unknown subcommand '")) (EApp (EVar "display") (EVar "sub"))) (ELit (LString "' (expected: write, show, verify)")))))
# MARK
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "spec" false) (mem "valueList" false) (mem "withStrictDash" false) (mem "parseArgs" false) (mem "flagValues" false) (mem "unknownFlagMessage" false))))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false))))
(DUse false (UseGroup ("crypto" "sha256") ((mem "sha256" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DUse false (UseGroup ("list") ((mem "zip" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "readPreludeFile" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeFrom" false) (mem "ppDiagCliSrc" false) (mem "diagIsError" false))))
(DUse false (UseGroup ("driver" "front_gate") ((mem "cliStdlibExports" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseLocated" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "baseName" false) (mem "joinPath" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "joinWith" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("types" "interface_sexp") ((mem "PreludeInterfaceFile" true) (mem "InterfaceSection" true) (mem "formatVersion" false) (mem "encodeInterface" false) (mem "decodeInterface" false) (mem "mergeSections" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "PreludeInterface" true) (mem "InterfaceKey" true) (mem "interfaceKeyOf" false) (mem "keysMatch" false) (mem "currentPreludeInterface" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ppPubScheme" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "lookupProfile" false) (mem "selectedProfile" false))))
(DTypeSig true "interfaceHelpText" (TyCon "String"))
(DFunDef false "interfaceHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka interface — Write, show and verify the prelude interface file\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka interface write  <module.mdk> [--target <profile>]...\n")) (ELit (LString "  medaka interface show   <file.mdki>\n")) (ELit (LString "  medaka interface verify <module.mdk>\n")) (ELit (LString "\n")) (ELit (LString "  write   type-checks the module (the prelude's core, with runtime.mdk beside\n")) (ELit (LString "          it) under each --target profile and writes <module>.mdki beside it.\n")) (ELit (LString "          Without --target the profiles are the full IO join and\n")) (ELit (LString "          wasmgc/browser-worker.  A module with a type error leaves no file.\n")) (ELit (LString "  show    prints the header and every published row.\n")) (ELit (LString "  verify  prints `fresh`, `stale: <component>` or `missing`; exit 0 only on\n")) (ELit (LString "          `fresh`.\n")))))
(DTypeSig false "writeSpec" (TyCon "ArgSpec"))
(DFunDef false "writeSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "interface write"))) (EListLit (EApp (EApp (EApp (EVar "valueList") (EListLit (ELit (LString "--target")))) (ELit (LString "PROFILE"))) (ELit (LString "a target profile whose IO join gets a section (repeatable)")))))))
(DTypeSig false "plainSpec" (TyFun (TyCon "String") (TyCon "ArgSpec")))
(DFunDef false "plainSpec" ((PVar "verb")) (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (EVar "verb")) (EListLit))))
(DTypeSig false "sha256Of" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sha256Of" ((PVar "text")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256") (EApp (EVar "encodeUtf8") (EVar "text")))))
(DTypeSig false "keyOfSources" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "InterfaceKey")))))
(DFunDef false "keyOfSources" ((PVar "coreName") (PVar "runtimeSrc") (PVar "coreSrc")) (EApp (EApp (EApp (EVar "interfaceKeyOf") (EVar "formatVersion")) (EListLit (ETuple (ELit (LString "runtime.mdk")) (EApp (EVar "sha256Of") (EVar "runtimeSrc"))) (ETuple (EVar "coreName") (EApp (EVar "sha256Of") (EVar "coreSrc"))))) (EApp (EVar "buildFingerprint") (ELit LUnit))))
(DTypeSig false "interfacePath" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "interfacePath" ((PVar "modulePath")) (EBinOp "++" (EVar "modulePath") (ELit (LString "i"))))
(DTypeSig false "runtimePathOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "runtimePathOf" ((PVar "modulePath")) (EApp (EApp (EVar "joinPath") (EApp (EVar "dirOf") (EVar "modulePath"))) (ELit (LString "runtime.mdk"))))
(DTypeSig false "defaultTargets" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "defaultTargets" () (EListLit (ELit (LString "")) (ELit (LString "wasmgc/browser-worker"))))
(DTypeSig false "profileOfTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "TargetProfile")))))
(DFunDef false "profileOfTarget" ((PLit (LString ""))) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "profileOfTarget" ((PVar "name")) (EApp (EApp (EMethodRef "map") (EVar "Some")) (EApp (EVar "lookupProfile") (EVar "name"))))
(DTypeSig false "driveUnder" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "TargetProfile")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "PreludeInterface")))))))))))
(DFunDef false "driveUnder" ((PVar "stdlibDir") (PVar "modulePath") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "profile")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "selectedProfile"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "profile"))) (DoLet false false (PVar "exports") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (DoLet false false (PVar "errors") (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "exports")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (EVar "coreSrc"))))) (DoLet false false (PVar "trivial") (EMatch (EVar "errors") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "exports")) (ELit (LString ""))) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (ELit (LString "x = 1\n"))))) (arm PWild () (EListLit)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EVar "saved"))) (DoExpr (EMatch (ETuple (EVar "errors") (EApp (EMethodRef "length") (EVar "trivial"))) (arm (PTuple (PList) PWild) () (EMatch (EApp (EVar "currentPreludeInterface") (ELit LUnit)) (arm (PList) () (EApp (EVar "Err") (ELit (LString "medaka interface write: the check left no prelude interface")))) (arm (PVar "sections") () (EApp (EVar "Ok") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "s")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "j")) (ETuple (EVar "j") (EApp (EVar "snd") (EVar "s"))))) (EApp (EVar "fst") (EVar "s"))))) (EVar "sections")))))) (arm PWild () (EApp (EVar "Err") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "coreSrc")) (EVar "modulePath"))) (EVar "errors")))))))))
(DTypeSig false "driveAll" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "TargetProfile"))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "PreludeInterface")))))))))))
(DFunDef false "driveAll" (PWild PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "driveAll" ((PVar "stdlibDir") (PVar "modulePath") (PVar "runtimeSrc") (PVar "coreSrc") (PCons (PVar "p") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "driveUnder") (EVar "stdlibDir")) (EVar "modulePath")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "p")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "here")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "here") (EVar "_s")))) (EApp (EApp (EApp (EApp (EApp (EVar "driveAll") (EVar "stdlibDir")) (EVar "modulePath")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "rest"))))))
(DTypeSig true "buildInterfaceFile" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PreludeInterfaceFile"))))))
(DFunDef false "buildInterfaceFile" ((PVar "modulePath") (PVar "targets")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readPreludeFile") (EApp (EVar "runtimePathOf") (EVar "modulePath")))) (ELam ((PVar "runtimeSrc")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readPreludeFile") (EVar "modulePath"))) (ELam ((PVar "coreSrc")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "resultList") (EApp (EApp (EMethodRef "map") (EVar "profileOfTarget")) (EIf (EApp (EMethodRef "isEmpty") (EVar "targets")) (EVar "defaultTargets") (EVar "targets"))))) (ELam ((PVar "profiles")) (ELet false (PVar "drive") (EApp (EApp (EApp (EApp (EVar "driveAll") (EApp (EVar "dirOf") (EVar "modulePath"))) (EVar "modulePath")) (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "drive") (EVar "profiles"))) (ELam ((PVar "drives")) (EApp (EVar "Ok") (ERecordCreate "PreludeInterfaceFile" ((fa "ifKey" (EApp (EApp (EApp (EVar "keyOfSources") (EApp (EVar "baseName") (EVar "modulePath"))) (EVar "runtimeSrc")) (EVar "coreSrc"))) (fa "ifSections" (EApp (EVar "mergeSections") (EVar "drives"))))))))))))))))
(DTypeSig false "resultList" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "resultList" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "resultList" ((PCons (PVar "r") (PVar "rest"))) (EMatch (EVar "r") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "x")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "resultList") (EVar "rest"))))))
(DTypeSig false "writeAtomically" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "writeAtomically" ((PVar "path") (PVar "text")) (EBlock (DoLet false false (PVar "staging") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ".new."))) (EApp (EMethodRef "display") (EApp (EApp (EVar "S.take") (ELit (LInt 16))) (EApp (EVar "sha256Of") (EVar "text"))))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "staging")) (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot write `")) (EApp (EMethodRef "display") (EVar "staging"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "rename") (EVar "staging")) (EVar "path")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EVar "staging"))) (DoExpr (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot move `")) (EApp (EMethodRef "display") (EVar "staging"))) (ELit (LString "` to `"))) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))))))))))))
(DTypeSig false "failWith" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "failWith" ((PVar "msg")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))
(DTypeSig false "writeCmd" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeCmd" ((PVar "modulePath") (PVar "targets")) (EMatch (EApp (EApp (EVar "buildInterfaceFile") (EVar "modulePath")) (EVar "targets")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EVar "e"))) (arm (PCon "Ok" (PVar "file")) () (EMatch (EApp (EApp (EVar "writeAtomically") (EApp (EVar "interfacePath") (EVar "modulePath"))) (EApp (EVar "encodeInterface") (EVar "file"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface write: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "wrote ")) (EApp (EMethodRef "display") (EApp (EVar "interfacePath") (EVar "modulePath")))) (ELit (LString "")))))))))
(DTypeSig false "joinView" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "joinView" ((PVar "j")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "renderAtom")) (EVar "j"))))
(DTypeSig false "digestOfText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "digestOfText" ((PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "(digest "))) (EVar "text")) (arm (PCon "None") () (ELit (LString "?"))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "tail") (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 8)))) (EVar "text"))) (DoExpr (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString ")"))) (EVar "tail")) (arm (PCon "Some" (PVar "j")) () (EApp (EApp (EVar "S.take") (EVar "j")) (EVar "tail"))) (arm (PCon "None") () (ELit (LString "?")))))))))
(DTypeSig false "sectionLines" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "InterfaceSection") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sectionLines" ((PVar "n") (PVar "total") (PVar "s")) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "section ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EVar "total"))) (ELit (LString "")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "j")) (EBinOp "++" (EBinOp "++" (ELit (LString "  join ")) (EApp (EMethodRef "display") (EApp (EVar "joinView") (EVar "j")))) (ELit (LString ""))))) (EFieldAccess (EVar "s") "isJoins"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  row ")) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "row")))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppPubScheme") (EApp (EVar "snd") (EVar "row"))))) (ELit (LString ""))))) (EFieldAccess (EFieldAccess (EVar "s") "isInterface") "piCore"))))
(DTypeSig true "showLines" (TyFun (TyCon "String") (TyFun (TyCon "PreludeInterfaceFile") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "showLines" ((PVar "digest") (PVar "f")) (EBlock (DoLet false false (PVar "total") (EApp (EMethodRef "length") (EFieldAccess (EVar "f") "ifSections"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "format ")) (EApp (EMethodRef "display") (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikFormat"))) (ELit (LString "")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "source ")) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "s")))) (ELit (LString " sha256 "))) (EApp (EMethodRef "display") (EApp (EVar "snd") (EVar "s")))) (ELit (LString ""))))) (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikSources"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "compiler ")) (EApp (EMethodRef "display") (EFieldAccess (EFieldAccess (EVar "f") "ifKey") "ikCompiler"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "sections ")) (EApp (EMethodRef "display") (EVar "total"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "digest ")) (EApp (EMethodRef "display") (EVar "digest"))) (ELit (LString ""))))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "sectionLines") (EApp (EVar "fst") (EVar "p"))) (EVar "total")) (EApp (EVar "snd") (EVar "p"))))) (EApp (EApp (EVar "zip") (ERangeList (ELit (LInt 1)) (EVar "total") true)) (EFieldAccess (EVar "f") "ifSections")))))))
(DTypeSig false "showCmd" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "showCmd" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface show: cannot read `")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "decodeInterface") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface show: `")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "seWhat"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "f")) () (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "showLines") (EApp (EVar "digestOfText") (EVar "text"))) (EVar "f")))))))))
(DData Public "Verdict" () ((variant "Fresh" (ConPos)) (variant "Stale" (ConPos (TyCon "String"))) (variant "Missing" (ConPos))) ())
(DTypeSig true "verdictText" (TyFun (TyCon "Verdict") (TyCon "String")))
(DFunDef false "verdictText" ((PCon "Fresh")) (ELit (LString "fresh")))
(DFunDef false "verdictText" ((PCon "Stale" (PVar "component"))) (EBinOp "++" (EBinOp "++" (ELit (LString "stale: ")) (EApp (EMethodRef "display") (EVar "component"))) (ELit (LString ""))))
(DFunDef false "verdictText" ((PCon "Missing")) (ELit (LString "missing")))
(DTypeSig true "verdictOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Verdict"))))
(DFunDef false "verdictOf" ((PVar "modulePath")) (EMatch (EApp (EVar "readFile") (EApp (EVar "interfacePath") (EVar "modulePath"))) (arm (PCon "Err" PWild) () (EVar "Missing")) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EVar "decodeInterface") (EVar "text")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Stale") (EIf (EApp (EApp (EVar "S.contains") (ELit (LString "format version"))) (EFieldAccess (EVar "e") "seWhat")) (ELit (LString "format")) (ELit (LString "file"))))) (arm (PCon "Ok" (PVar "f")) () (EMatch (ETuple (EApp (EVar "readFile") (EApp (EVar "runtimePathOf") (EVar "modulePath"))) (EApp (EVar "readFile") (EVar "modulePath"))) (arm (PTuple (PCon "Ok" (PVar "runtimeSrc")) (PCon "Ok" (PVar "coreSrc"))) () (EMatch (EApp (EApp (EVar "keysMatch") (EFieldAccess (EVar "f") "ifKey")) (EApp (EApp (EApp (EVar "keyOfSources") (EApp (EVar "baseName") (EVar "modulePath"))) (EVar "runtimeSrc")) (EVar "coreSrc"))) (arm (PCon "None") () (EVar "Fresh")) (arm (PCon "Some" (PVar "component")) () (EApp (EVar "Stale") (EVar "component"))))) (arm PWild () (EApp (EVar "Stale") (ELit (LString "sources"))))))))))
(DTypeSig false "verifyCmd" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "verifyCmd" ((PVar "modulePath")) (EBlock (DoLet false false (PVar "verdict") (EApp (EVar "verdictOf") (EVar "modulePath"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "verdictText") (EVar "verdict")))) (DoExpr (EMatch (EVar "verdict") (arm (PCon "Fresh") () (ELit LUnit)) (arm PWild () (EApp (EVar "stageExit") (ELit (LInt 1))))))))
(DTypeSig false "wantsHelp" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "wantsHelp" ((PCons (PLit (LString "--help")) PWild)) (EVar "True"))
(DFunDef false "wantsHelp" ((PCons (PLit (LString "-h")) PWild)) (EVar "True"))
(DFunDef false "wantsHelp" (PWild) (EVar "False"))
(DTypeSig false "printHelp" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printHelp" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "interfaceHelpText"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DTypeSig false "oneModule" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "oneModule" ((PVar "sp") (PVar "argv") (PVar "run")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "sp")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "failWith") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList (PVar "path")) () (EApp (EVar "run") (EVar "path"))) (arm (PList) () (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "usage: ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sp") "verb"))) (ELit (LString " <path>"))))) (arm (PCons PWild (PCons (PVar "extra") PWild)) () (EApp (EVar "failWith") (EApp (EApp (EVar "unknownFlagMessage") (EVar "sp")) (EVar "extra"))))))))
(DTypeSig false "writeArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeArgs" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "writeSpec")) (EVar "argv")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "failWith") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList (PVar "path")) () (EApp (EApp (EVar "writeCmd") (EVar "path")) (EApp (EApp (EVar "flagValues") (ELit (LString "--target"))) (EVar "a")))) (arm (PList) () (EApp (EVar "failWith") (ELit (LString "usage: medaka interface write <module.mdk> [--target <profile>]...")))) (arm (PCons PWild (PCons (PVar "extra") PWild)) () (EApp (EVar "failWith") (EApp (EApp (EVar "unknownFlagMessage") (EVar "writeSpec")) (EVar "extra"))))))))
(DTypeSig true "runInterfaceCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runInterfaceCmd" ((PList)) (EApp (EVar "failWith") (ELit (LString "usage: medaka interface <write|show|verify> <module.mdk>"))))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "write")) (PVar "rest"))) (EIf (EApp (EVar "wantsHelp") (EVar "rest")) (EApp (EVar "printHelp") (ELit LUnit)) (EApp (EVar "writeArgs") (EVar "rest"))))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "show")) (PVar "rest"))) (EIf (EApp (EVar "wantsHelp") (EVar "rest")) (EApp (EVar "printHelp") (ELit LUnit)) (EApp (EApp (EApp (EVar "oneModule") (EApp (EVar "plainSpec") (ELit (LString "interface show")))) (EVar "rest")) (EVar "showCmd"))))
(DFunDef false "runInterfaceCmd" ((PCons (PLit (LString "verify")) (PVar "rest"))) (EIf (EApp (EVar "wantsHelp") (EVar "rest")) (EApp (EVar "printHelp") (ELit LUnit)) (EApp (EApp (EApp (EVar "oneModule") (EApp (EVar "plainSpec") (ELit (LString "interface verify")))) (EVar "rest")) (EVar "verifyCmd"))))
(DFunDef false "runInterfaceCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "failWith") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka interface: unknown subcommand '")) (EApp (EMethodRef "display") (EMethodRef "sub"))) (ELit (LString "' (expected: write, show, verify)")))))
