# META
source_lines=564
stages=DESUGAR,MARK
# SOURCE
-- compiler/driver/front_gate.mdk — the front-end error renderers the CLI verbs
-- share, and `build`'s front-end gate, which the `medaka_emitter` child runs
-- when the `build` verb asks for it (`frontGateEnv`).  Nothing here reads the
-- process environment except `frontGateOfEnv` and `diagJsonPathOfEnv`: the
-- stdlib directory is a parameter.  So a caller that is not the CLI dispatcher
-- (the emitter child) can import this module without `medaka_cli.mdk`.

import frontend.ast.{Decl, Loc(..)}
import types.typecheck.{TcDiag, setStdlibOwnership}
import json.{Json(..), parse, stringify}
import frontend.parser.{
  parseLocated,
  parseResult,
  ParseError,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
}
import frontend.desugar.{desugarIn}
import frontend.desugar_cache.{desugaredPrelude, desugaredPreludeKey}
import frontend.resolve.{internalGuardFor, resolveModulesErrorsByFile}
import driver.diagnostics.{
  CheckJson(..),
  Diag(..),
  Severity(..),
  analyzeFinish,
  analyzeSurface,
  bucketsResolveRejected,
  cjDiagnostic,
  cjFoldIntoFile,
  cjGraphParts,
  cjLoadFailure,
  cjSingleParts,
  ppCheckJson,
  readFileSafe,
  resolveLoadedBuckets,
  tcHalfOfPerModule,
  typecheckDiagsFold,
  typecheckLoadedBuckets,
  hintResErrorPairs,
  mainEntryError,
  ppDiagCliLines,
  ppDiagCliSrc,
  ppMainEntryError,
  ppResolveErrorsByFile,
  parseErrHelpFix,
  parseErrCode,
  srcLinesArr,
  stdlibExportsReader,
  surfaceErrors,
}
import driver.loader.{
  LoadError(..),
  dropPathTriple,
  entrySearchRoots,
  loadProgramFilesLocatedE,
  modIdToPath,
  projectTrustedMods,
  readSource,
  stdlibOwnership,
  unknownModuleIdOf,
  findImportLoc,
  availableModulesHint,
}
import support.path.{dirOf}
import support.util.{contains, joinNl, splitLast}
import support.stage_count.{stageExit}

-- The import hint's reader for `check`/`run`/`build`: `stdlibDir` is the stdlib
-- directory every verb resolves `stdlib/` against, supplied by the caller.
-- Called only once resolve has reported an unbound name (`hintResErrors`).
export
cliStdlibExports : String -> List String -> <IO> List (String, List String)
cliStdlibExports stdlibDir names = stdlibExportsReader stdlibDir names

-- PARSE-ERROR-LOCATION Stage 1: render a located `ParseError` through the SAME
-- caret-aware `ppDiagCliSrc` + `Diag` machinery the typecheck/resolve text paths
-- use, so EVERY CLI-text parse error gets `file:L:C:` + a source snippet + caret
-- + the stable `P-*`/`L-*` code (and, for the clean single-token hints, a `help`).
-- `parseErrorLine` is 1-based, `parseErrorCol` 0-based — the exact convention
-- `ppDiagCliSrc`/`parseErrHelpFix` expect (matching the `--json` inline build).
export
ppParseError : String -> String -> ParseError -> String
ppParseError src file e =
  let ploc =
    Loc
      file
      (parseErrorLine e)
      (parseErrorCol e)
      (parseErrorLine e)
      (parseErrorCol e + 1)
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

-- F3 Chunk B (R-MODULE-LOAD): the loader's `Err "unknown module: X"` carries no
-- location (see loader.mdk's entry-scan doc comment).  `tsrc` is already known
-- to parse (the caller re-checks `parseResult` in its loader-failure arm), so
-- re-parse it with `parseLocated` (real ELoc/DUse spans) and look up the failing modId's own
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
-- #2400 F2b: `mpath` is LOADER-MINTED (`./bad.mdk` for a module beside an entry
-- named with no directory part), unlike every other `ppParseError` call site,
-- which passes the CLI's own target string.  Same one-file-two-spellings defect
-- the resolve and type-error channels had; `ppDiagCliLines` (which `ppParseError`
-- renders through) applies the `displayPath` answer for every arm, so nothing is
-- normalised here.  `msrc` is deliberately the module's OWN source, so the caret
-- keeps naming the module that is actually broken (#100).
export
moduleLoadErrText : String -> String -> String -> LoadError -> <IO> String
moduleLoadErrText _ _ _ (LoadParseFailed mpath msrc e) =
  ppParseError msrc mpath e
moduleLoadErrText _ _ _ (LoadCycle lmsg cpath csite) = match csite
  None => lmsg
  Some (csrc, loc) =>
    ppDiagCliSrc
      csrc
      cpath
      (Diag SevError "R-MODULE-LOAD" lmsg (Some loc) None None)
moduleLoadErrText tsrc target stdlibDir (LoadMsg lmsg) =
  match unknownModuleIdOf lmsg
    None => lmsg
    Some mid =>
      let msg = lmsg ++ availableModulesHint stdlibDir
      match findImportLoc mid (parseLocated tsrc)
        None => msg
        Some loc =>
          ppDiagCliSrc
            tsrc
            target
            (Diag SevError "R-MODULE-LOAD" msg (Some loc) None None)

-- ── the `build` front-end gate ───────────────────────────────────────────────
-- `medaka build` sets this variable on the `medaka_emitter` child it spawns, and
-- nothing else does: the bootstrap, the fixpoint, the gates that run an emitter
-- directly and `medaka test --native`'s children start it without the variable
-- and keep the ungated driver.  Not an argv flag, because the emitter reads
-- every argument after the entry as a search root.  The value carries
-- `--allow-internal`.
export
frontGateEnv : String
frontGateEnv = "MEDAKA_FRONT_GATE"

-- The `env` assignment that asks the child for the gate.
export
frontGateAssignment : Bool -> String
frontGateAssignment True = "\{frontGateEnv}=allow-internal"
frontGateAssignment False = "\{frontGateEnv}=1"

-- `Some allowInternal` when the parent asked for the gate.
export
frontGateOfEnv : Unit -> <IO> Option Bool
frontGateOfEnv _ = match getEnv frontGateEnv
  None => None
  Some "" => None
  Some "allow-internal" => Some True
  Some _ => Some False

-- What the gate hands on when it admits a program: the search roots it loaded
-- with, the loader's (module, path, raw decls) graph with the entry last, and
-- the desugared trees elaboration reads, so the program is loaded, parsed and
-- desugared once.
public export data FrontGraph = FrontGraph {
  fgRoots : List String,
  fgMods : List (String, String, List Decl),
  fgRuntimeD : List Decl,
  fgCoreD : List Decl,
  fgModsD : List (String, List Decl),
}

-- `build`'s front-end verdict on `entry`: load, a located parse or load error,
-- resolve, then the `main` refusal, each rendered as `check` renders it.  The
-- search roots are the entry's own (`entrySearchRoots`) and the stdlib, the set
-- every verb loads with, and never the emitter's argv roots, which also name
-- the compiler's own sources.  The prelude sources were validated by the
-- parent (`readPreludeFile`); `stdlibDir` is the directory holding them.
export
frontGate : Bool ->
  String ->
  String ->
  String ->
  String ->
  <IO> Result String FrontGraph
frontGate allowInternal stdlibDir rsrc csrc entry =
  let roots = entrySearchRoots (dirOf entry) ++ [stdlibDir]
  match loadProgramFilesLocatedE (_ => None) entry roots
    Err lerr => Err (loadRefusal stdlibDir entry lerr)
    Ok mods =>
      let pairs = map dropPathTriple mods
      let graph = frontGraphOf roots rsrc csrc mods
      let trusted = projectTrustedMods entry roots stdlibDir pairs
      let resolved =
        resolveRefusal allowInternal stdlibDir trusted rsrc csrc entry graph
      match resolved
        Some msg => Err msg
        None => match mainRefusal entry pairs
          Some msg => Err msg
          None => Ok graph

frontGraphOf : List String ->
  String ->
  String ->
  List (String, String, List Decl) ->
  FrontGraph
frontGraphOf roots rsrc csrc mods = FrontGraph {
  fgRoots = roots,
  fgMods = mods,
  fgRuntimeD = desugaredPrelude rsrc,
  fgCoreD = desugaredPrelude csrc,
  fgModsD = map ((mid, _, p) => (mid, desugarIn mid p)) mods,
}

-- A failed load: the entry's own parse error if it has one, else the loader's
-- error.  The entry is read here, not before the load, so a valid entry is read
-- once; an entry the loader could not read fails `readSource` the same way.
loadRefusal : String -> String -> LoadError -> <IO> String
loadRefusal stdlibDir entry lerr = match readSource entry
  Err e => e
  Ok tsrc => match parseResult tsrc
    Err e => ppParseError tsrc entry e
    Ok _ => moduleLoadErrText tsrc entry stdlibDir lerr

-- Resolve's verdict, by module count.  One module: the errors of the raw-tree
-- surface passes (`surfaceErrors`), against the entry file.  A graph: each
-- module's resolve errors against its own file (`resolveModulesErrorsByFile`),
-- the seam `check` uses.
resolveRefusal : Bool ->
  String ->
  List String ->
  String ->
  String ->
  String ->
  FrontGraph ->
  <IO> Option String
resolveRefusal allowInternal stdlibDir trusted rsrc csrc entry g =
  let trees = (g.fgMods, g.fgModsD)
  match trees
    ([(mid, _, raw)], [(_, desugared)]) =>
      let errs =
        surfaceErrors
          (cliStdlibExports stdlibDir)
          g.fgRuntimeD
          g.fgCoreD
          raw
          desugared
          (internalGuardFor (allowInternal || contains mid trusted))
      match errs
        [] => None
        _ =>
          let lines = srcLinesArr (entrySource entry)
          Some (joinNl (map (ppDiagCliLines lines entry) errs))
    _ =>
      let text =
        ppResolveErrorsByFile
          (hintResErrorPairs
            (cliStdlibExports stdlibDir)
            (resolveModulesErrorsByFile
              (map modIdToPath g.fgMods)
              allowInternal
              trusted
              (Some (desugaredPreludeKey rsrc, desugaredPreludeKey csrc))
              g.fgRuntimeD
              g.fgCoreD
              g.fgModsD))
      if text == "" then None else Some text

-- A program `build` cannot start: a function-shaped `main` or none at all in
-- the entry, which the loader puts last.
mainRefusal : String -> List (String, List Decl) -> <IO> Option String
mainRefusal entry pairs = match splitLast pairs
  None => None
  Some (_, (_, decls)) =>
    map
      (d => ppMainEntryError (entrySource entry) entry d)
      (mainEntryError decls)

-- The entry's text, for rendering a refusal; the loader has already read it.
entrySource : String -> <IO> String
entrySource entry = match readFile entry
  Ok src => src
  Err _ => ""

-- ── `build --json`: the gate's verdict as `check --json`'s envelope ─────────
-- On the `--json` route the child also gets `diagJsonEnv`, naming a file in the
-- parent's scratch directory.  It writes there the envelope `check --json`
-- prints for the program, from its one drive: once for a refusal, before it
-- exits `emitDiagExitCode`, and once after a successful emit for a clean
-- program.  Nothing else is written there, so the parent reads the file only
-- when the child exited 0 or with that code.  Its first line is the entry's
-- bucket key as a JSON string ("" for an envelope rendered whole), so the
-- parent can fold its own build notes into that file's diagnostics.

-- What `build` asks of the child's gate: the `--allow-internal` bit, and
-- whether the verdict also goes to the envelope file.
public export data GateAsk = GateAsk {
  askAllowInternal : Bool,
  askDiagJson : Bool,
}

export
diagJsonEnv : String
diagJsonEnv = "MEDAKA_DIAG_JSON"

-- The acknowledgement file: the child writes it once the gate has run and
-- delivered its verdict, so a parent that asked for the gate can tell a child
-- that ran it from an older emitter that ignores `frontGateEnv`.
export
gateAckEnv : String
gateAckEnv = "MEDAKA_FRONT_GATE_ACK"

-- The `env` assignments that ask the child for the gate, writing the envelope
-- to `diagPath` when the ask says so and the acknowledgement to `ackPath`.
-- Every variable is set, to empty when unused, so one inherited from the
-- caller's environment never steers the child.
export
gateAssignments : GateAsk -> String -> String -> List String
gateAssignments ask diagPath ackPath = [
  frontGateAssignment ask.askAllowInternal,
  "\{diagJsonEnv}=\{if ask.askDiagJson then diagPath else ""}",
  "\{gateAckEnv}=\{ackPath}",
]

-- The assignments for a child that is not asked for the gate.
export
noGateAssignments : List String
noGateAssignments = ["\{frontGateEnv}=", "\{diagJsonEnv}=", "\{gateAckEnv}="]

-- The child's acknowledgement, when the parent asked for one.
export
writeGateAck : Unit -> <IO> Unit
writeGateAck _ = match getEnv gateAckEnv
  None => ()
  Some "" => ()
  Some path => match writeFile path "ran\n"
    Ok _ => ()
    Err e =>
      let _ =
        ePutStrLn
          "error: could not write the gate acknowledgement to \{path}: \{e}"
      stageExit 1

export
diagJsonPathOfEnv : Unit -> <IO> Option String
diagJsonPathOfEnv _ = match getEnv diagJsonEnv
  None => None
  Some "" => None
  Some p => Some p

-- What the `--json` gate keeps for the envelope after the drive.  One module:
-- the entry's spelling, its source, the surface passes' diagnostics (none of
-- them a resolve error, which stopped the gate) and its located decls.  A
-- graph: the entry's spelling, the stdlib directory and the per-file resolve
-- buckets.
public export data JsonFront =
  | JsonSingle String String (List Diag) (List Decl)
  | JsonGraph String String (List (String, List Diag))

-- `frontGate` for the `--json` route: a refusal is `check --json`'s envelope
-- for the program.  Resolve runs as `check` runs it, so a refused graph's
-- envelope also carries what `check` reports for the modules resolve did not
-- block; that drive is the build's only one, since nothing is emitted.  The
-- `main` refusal waits for the drive (`frontJsonAfterDrive`): an envelope
-- with an error outranks it.
export
frontGateJson : Bool ->
  String ->
  String ->
  String ->
  String ->
  <IO> Result CheckJson (FrontGraph, JsonFront)
frontGateJson allowInternal stdlibDir rsrc csrc entry =
  let roots = entrySearchRoots (dirOf entry) ++ [stdlibDir]
  match loadProgramFilesLocatedE (_ => None) entry roots
    Err lerr => Err (cjLoadFailure entry (readFileSafe entry) stdlibDir lerr)
    Ok mods =>
      let pairs = map dropPathTriple mods
      let graph = frontGraphOf roots rsrc csrc mods
      let trusted = projectTrustedMods entry roots stdlibDir pairs
      let (flatStdlib, ownedStdlib) =
        stdlibOwnership entry roots stdlibDir pairs
      let _ = setStdlibOwnership flatStdlib ownedStdlib
      match mods
        [(mid, _, raw)] =>
          let src = readFileSafe entry
          let surface =
            analyzeSurface
              (cliStdlibExports stdlibDir)
              mid
              rsrc
              csrc
              raw
              (internalGuardFor (allowInternal || contains mid trusted))
          let diags = analyzeFinish surface []
          if surface.resolveClean then
            Ok (graph, JsonSingle entry src diags raw)
          else
            Err (fst (cjSingleParts entry src raw diags))
        _ =>
          let buckets =
            resolveLoadedBuckets
              (cliStdlibExports stdlibDir)
              allowInternal
              trusted
              entry
              roots
              rsrc
              csrc
              mods
              graph.fgModsD
          if bucketsResolveRejected buckets then
            let (_, results) =
              typecheckLoadedBuckets
                entry
                roots
                rsrc
                csrc
                mods
                graph.fgModsD
                buckets
            Err (fst (cjGraphParts entry stdlibDir pairs results))
          else
            Ok (graph, JsonGraph entry stdlibDir buckets)

-- The `--json` route's verdict once the build's drive has run: the envelope
-- with its errors, else the `main` refusal, else the target refusal folded
-- into the clean envelope, in the order `build --json` reports them.  `Ok` is
-- the clean envelope.  `perMod` is the drive's per-module diagnostics, read
-- with the surface ones as `check` reads them.
export
frontJsonAfterDrive : JsonFront ->
  List Decl ->
  List Decl ->
  List (String, String, List Decl) ->
  List (String, List Decl) ->
  List (String, (List TcDiag, List TcDiag)) ->
  Option Diag ->
  <IO> Result CheckJson CheckJson
frontJsonAfterDrive front rtD coreD mods modsD perMod refusal =
  let (cj, hasErr) = match front
    JsonSingle target src surface raw =>
      cjSingleParts target src raw (surface ++ tcHalfOfPerModule perMod)
    JsonGraph target stdlibDir buckets =>
      cjGraphParts
        target
        stdlibDir
        (map dropPathTriple mods)
        (typecheckDiagsFold rtD coreD mods modsD perMod buckets)
  let entry = jsonFrontEntry front
  if hasErr then
    Err cj
  else match mainRefusalJson entry mods
    Some refused => Err refused
    None => match (refusal, cj)
      (Some d, CjParts key triples) =>
        Err (CjParts key (cjFoldIntoFile key [d] triples))
      _ => Ok cj

jsonFrontEntry : JsonFront -> String
jsonFrontEntry (JsonSingle target _ _ _) = target
jsonFrontEntry (JsonGraph target _ _) = target

-- The `main` refusal as its own envelope against the entry's spelling.
mainRefusalJson : String ->
  List (String, String, List Decl) ->
  <IO> Option CheckJson
mainRefusalJson entry mods = match splitLast mods
  None => None
  Some (_, (_, _, decls)) =>
    map
      (d => CjParts entry [(entry, readFileSafe entry, [d])])
      (mainEntryError decls)

-- The child's write: the key line, then the envelope.  A file it cannot write
-- is a build failure in its own words, not an envelope the parent never sees.
export
writeDiagJson : String -> CheckJson -> <IO> Unit
writeDiagJson path cj =
  let key = match cj
    CjParts k _ => k
    CjRendered _ => ""
  match writeFile path "\{stringify (JString key)}\n\{ppCheckJson cj}"
    Ok _ => ()
    Err e =>
      let _ =
        ePutStrLn
          "error: could not write the diagnostics envelope to \{path}: \{e}"
      stageExit 1

-- The parent's read: (entry key, envelope), or `None` when the child wrote
-- nothing there.
export
readDiagJson : String -> <IO> Option (String, String)
readDiagJson path = match readFile path
  Err _ => None
  Ok text => match stringIndexOf "\n" text
    None => None
    Some i => match parse (stringSlice 0 i text)
      Ok (JString key) =>
        Some (key, stringSlice (i + 1) (stringLength text) text)
      _ => None

-- The envelope with the build's own notes (#2243) appended to the entry
-- file's `diagnostics`, as `cjFoldIntoFile` folds them: the first file whose
-- key matches, and none when no file does.  With no notes the child's bytes
-- are returned as they are.
export
envelopeWithNotes : String -> List Diag -> String -> String
envelopeWithNotes _ [] envelope = envelope
envelopeWithNotes key notes envelope = match parse envelope
  Ok (JObject members) =>
    stringify
      (JObject
        (arrayFromList (map (filesWithNotes key notes) (toList members))))
  _ => envelope

filesWithNotes : String -> List Diag -> (String, Json) -> (String, Json)
filesWithNotes key notes ("files", JArray files) = (
  "files",
  JArray (arrayFromList (foldNotesInto key notes (toList files))),
)
filesWithNotes _ _ member = member

foldNotesInto : String -> List Diag -> List Json -> List Json
foldNotesInto _ _ [] = []
foldNotesInto key notes (file :: rest) = match fileWithNotes key notes file
  Some folded => folded :: rest
  None => file :: foldNotesInto key notes rest

fileWithNotes : String -> List Diag -> Json -> Option Json
fileWithNotes key notes (JObject members) = match toList members
  [("file", JString p), ("diagnostics", JArray ds)] =>
    if p == key then
      Some
        (JObject
          (arrayFromList [
            ("file", JString p),
            (
              "diagnostics",
              JArray
                (arrayFromList (toList ds ++ map (cjDiagnostic p "") notes)),
            ),
          ]))
    else
      None
  _ => None
fileWithNotes _ _ _ = None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("types" "typecheck") ((mem "TcDiag" false) (mem "setStdlibOwnership" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "parse" false) (mem "stringify" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseLocated" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugarIn" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "desugaredPreludeKey" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "internalGuardFor" false) (mem "resolveModulesErrorsByFile" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "CheckJson" true) (mem "Diag" true) (mem "Severity" true) (mem "analyzeFinish" false) (mem "analyzeSurface" false) (mem "bucketsResolveRejected" false) (mem "cjDiagnostic" false) (mem "cjFoldIntoFile" false) (mem "cjGraphParts" false) (mem "cjLoadFailure" false) (mem "cjSingleParts" false) (mem "ppCheckJson" false) (mem "readFileSafe" false) (mem "resolveLoadedBuckets" false) (mem "tcHalfOfPerModule" false) (mem "typecheckDiagsFold" false) (mem "typecheckLoadedBuckets" false) (mem "hintResErrorPairs" false) (mem "mainEntryError" false) (mem "ppDiagCliLines" false) (mem "ppDiagCliSrc" false) (mem "ppMainEntryError" false) (mem "ppResolveErrorsByFile" false) (mem "parseErrHelpFix" false) (mem "parseErrCode" false) (mem "srcLinesArr" false) (mem "stdlibExportsReader" false) (mem "surfaceErrors" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" true) (mem "dropPathTriple" false) (mem "entrySearchRoots" false) (mem "loadProgramFilesLocatedE" false) (mem "modIdToPath" false) (mem "projectTrustedMods" false) (mem "readSource" false) (mem "stdlibOwnership" false) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "joinNl" false) (mem "splitLast" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DTypeSig true "cliStdlibExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "cliStdlibExports" ((PVar "stdlibDir") (PVar "names")) (EApp (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir")) (EVar "names")))
(DTypeSig true "ppParseError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "ppParseError" ((PVar "src") (PVar "file") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EApp (EVar "parseErrorCol") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "h") (PVar "fx")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "h")) (EVar "fx"))))))
(DTypeSig true "moduleLoadErrText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "e"))) (EApp (EApp (EApp (EVar "ppParseError") (EVar "msrc")) (EVar "mpath")) (EVar "e")))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadCycle" (PVar "lmsg") (PVar "cpath") (PVar "csite"))) (EMatch (EVar "csite") (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PTuple (PVar "csrc") (PVar "loc"))) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "csrc")) (EVar "cpath")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "lmsg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))
(DFunDef false "moduleLoadErrText" ((PVar "tsrc") (PVar "target") (PVar "stdlibDir") (PCon "LoadMsg" (PVar "lmsg"))) (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EVar "lmsg") (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "tsrc"))) (arm (PCon "None") () (EVar "msg")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "msg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))))))
(DTypeSig true "frontGateEnv" (TyCon "String"))
(DFunDef false "frontGateEnv" () (ELit (LString "MEDAKA_FRONT_GATE")))
(DTypeSig true "frontGateAssignment" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "frontGateAssignment" ((PCon "True")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "frontGateEnv"))) (ELit (LString "=allow-internal"))))
(DFunDef false "frontGateAssignment" ((PCon "False")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "frontGateEnv"))) (ELit (LString "=1"))))
(DTypeSig true "frontGateOfEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Bool")))))
(DFunDef false "frontGateOfEnv" (PWild) (EMatch (EApp (EVar "getEnv") (EVar "frontGateEnv")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "None")) (arm (PCon "Some" (PLit (LString "allow-internal"))) () (EApp (EVar "Some") (EVar "True"))) (arm (PCon "Some" PWild) () (EApp (EVar "Some") (EVar "False")))))
(DData Public "FrontGraph" () ((variant "FrontGraph" (ConNamed (field "fgRoots" (TyApp (TyCon "List") (TyCon "String"))) (field "fgMods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "fgRuntimeD" (TyApp (TyCon "List") (TyCon "Decl"))) (field "fgCoreD" (TyApp (TyCon "List") (TyCon "Decl"))) (field "fgModsD" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))) ())
(DTypeSig true "frontGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "FrontGraph")))))))))
(DFunDef false "frontGate" ((PVar "allowInternal") (PVar "stdlibDir") (PVar "rsrc") (PVar "csrc") (PVar "entry")) (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "entry"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "loadRefusal") (EVar "stdlibDir")) (EVar "entry")) (EVar "lerr")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "map") (EVar "dropPathTriple")) (EVar "mods"))) (DoLet false false (PVar "graph") (EApp (EApp (EApp (EApp (EVar "frontGraphOf") (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "mods"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "entry")) (EVar "roots")) (EVar "stdlibDir")) (EVar "pairs"))) (DoLet false false (PVar "resolved") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveRefusal") (EVar "allowInternal")) (EVar "stdlibDir")) (EVar "trusted")) (EVar "rsrc")) (EVar "csrc")) (EVar "entry")) (EVar "graph"))) (DoExpr (EMatch (EVar "resolved") (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "mainRefusal") (EVar "entry")) (EVar "pairs")) (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "graph")))))))))))))
(DTypeSig false "frontGraphOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "FrontGraph"))))))
(DFunDef false "frontGraphOf" ((PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "mods")) (ERecordCreate "FrontGraph" ((fa "fgRoots" (EVar "roots")) (fa "fgMods" (EVar "mods")) (fa "fgRuntimeD" (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (fa "fgCoreD" (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (fa "fgModsD" (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "mid") PWild (PVar "p"))) (ETuple (EVar "mid") (EApp (EApp (EVar "desugarIn") (EVar "mid")) (EVar "p"))))) (EVar "mods"))))))
(DTypeSig false "loadRefusal" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "loadRefusal" ((PVar "stdlibDir") (PVar "entry") (PVar "lerr")) (EMatch (EApp (EVar "readSource") (EVar "entry")) (arm (PCon "Err" (PVar "e")) () (EVar "e")) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "entry")) (EVar "e"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "entry")) (EVar "stdlibDir")) (EVar "lerr")))))))
(DTypeSig false "resolveRefusal" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "FrontGraph") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))))))
(DFunDef false "resolveRefusal" ((PVar "allowInternal") (PVar "stdlibDir") (PVar "trusted") (PVar "rsrc") (PVar "csrc") (PVar "entry") (PVar "g")) (EBlock (DoLet false false (PVar "trees") (ETuple (EFieldAccess (EVar "g") "fgMods") (EFieldAccess (EVar "g") "fgModsD"))) (DoExpr (EMatch (EVar "trees") (arm (PTuple (PList (PTuple (PVar "mid") PWild (PVar "raw"))) (PList (PTuple PWild (PVar "desugared")))) () (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "surfaceErrors") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EFieldAccess (EVar "g") "fgRuntimeD")) (EFieldAccess (EVar "g") "fgCoreD")) (EVar "raw")) (EVar "desugared")) (EApp (EVar "internalGuardFor") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "None")) (arm PWild () (EBlock (DoLet false false (PVar "lines") (EApp (EVar "srcLinesArr") (EApp (EVar "entrySource") (EVar "entry")))) (DoExpr (EApp (EVar "Some") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EVar "lines")) (EVar "entry"))) (EVar "errs"))))))))))) (arm PWild () (EBlock (DoLet false false (PVar "text") (EApp (EVar "ppResolveErrorsByFile") (EApp (EApp (EVar "hintResErrorPairs") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsByFile") (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EFieldAccess (EVar "g") "fgMods"))) (EVar "allowInternal")) (EVar "trusted")) (EApp (EVar "Some") (ETuple (EApp (EVar "desugaredPreludeKey") (EVar "rsrc")) (EApp (EVar "desugaredPreludeKey") (EVar "csrc"))))) (EFieldAccess (EVar "g") "fgRuntimeD")) (EFieldAccess (EVar "g") "fgCoreD")) (EFieldAccess (EVar "g") "fgModsD"))))) (DoExpr (EIf (EBinOp "==" (EVar "text") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "text"))))))))))
(DTypeSig false "mainRefusal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "mainRefusal" ((PVar "entry") (PVar "pairs")) (EMatch (EApp (EVar "splitLast") (EVar "pairs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple PWild (PTuple PWild (PVar "decls")))) () (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EVar "ppMainEntryError") (EApp (EVar "entrySource") (EVar "entry"))) (EVar "entry")) (EVar "d")))) (EApp (EVar "mainEntryError") (EVar "decls"))))))
(DTypeSig false "entrySource" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "entrySource" ((PVar "entry")) (EMatch (EApp (EVar "readFile") (EVar "entry")) (arm (PCon "Ok" (PVar "src")) () (EVar "src")) (arm (PCon "Err" PWild) () (ELit (LString "")))))
(DData Public "GateAsk" () ((variant "GateAsk" (ConNamed (field "askAllowInternal" (TyCon "Bool")) (field "askDiagJson" (TyCon "Bool"))))) ())
(DTypeSig true "diagJsonEnv" (TyCon "String"))
(DFunDef false "diagJsonEnv" () (ELit (LString "MEDAKA_DIAG_JSON")))
(DTypeSig true "gateAckEnv" (TyCon "String"))
(DFunDef false "gateAckEnv" () (ELit (LString "MEDAKA_FRONT_GATE_ACK")))
(DTypeSig true "gateAssignments" (TyFun (TyCon "GateAsk") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "gateAssignments" ((PVar "ask") (PVar "diagPath") (PVar "ackPath")) (EListLit (EApp (EVar "frontGateAssignment") (EFieldAccess (EVar "ask") "askAllowInternal")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "diagJsonEnv"))) (ELit (LString "="))) (EApp (EVar "display") (EIf (EFieldAccess (EVar "ask") "askDiagJson") (EVar "diagPath") (ELit (LString ""))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "gateAckEnv"))) (ELit (LString "="))) (EApp (EVar "display") (EVar "ackPath"))) (ELit (LString "")))))
(DTypeSig true "noGateAssignments" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "noGateAssignments" () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "frontGateEnv"))) (ELit (LString "="))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "diagJsonEnv"))) (ELit (LString "="))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "gateAckEnv"))) (ELit (LString "=")))))
(DTypeSig true "writeGateAck" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeGateAck" (PWild) (EMatch (EApp (EVar "getEnv") (EVar "gateAckEnv")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PLit (LString ""))) () (ELit LUnit)) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EApp (EVar "writeFile") (EVar "path")) (ELit (LString "ran\n"))) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not write the gate acknowledgement to ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))))
(DTypeSig true "diagJsonPathOfEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "diagJsonPathOfEnv" (PWild) (EMatch (EApp (EVar "getEnv") (EVar "diagJsonEnv")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "None")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "Some") (EVar "p")))))
(DData Public "JsonFront" () ((variant "JsonSingle" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyCon "Decl")))) (variant "JsonGraph" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))) ())
(DTypeSig true "frontGateJson" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "CheckJson")) (TyTuple (TyCon "FrontGraph") (TyCon "JsonFront"))))))))))
(DFunDef false "frontGateJson" ((PVar "allowInternal") (PVar "stdlibDir") (PVar "rsrc") (PVar "csrc") (PVar "entry")) (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "entry"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EVar "cjLoadFailure") (EVar "entry")) (EApp (EVar "readFileSafe") (EVar "entry"))) (EVar "stdlibDir")) (EVar "lerr")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "map") (EVar "dropPathTriple")) (EVar "mods"))) (DoLet false false (PVar "graph") (EApp (EApp (EApp (EApp (EVar "frontGraphOf") (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "mods"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "entry")) (EVar "roots")) (EVar "stdlibDir")) (EVar "pairs"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "entry")) (EVar "roots")) (EVar "stdlibDir")) (EVar "pairs"))) (DoLet false false PWild (EApp (EApp (EVar "setStdlibOwnership") (EVar "flatStdlib")) (EVar "ownedStdlib"))) (DoExpr (EMatch (EVar "mods") (arm (PList (PTuple (PVar "mid") PWild (PVar "raw"))) () (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "entry"))) (DoLet false false (PVar "surface") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeSurface") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EVar "mid")) (EVar "rsrc")) (EVar "csrc")) (EVar "raw")) (EApp (EVar "internalGuardFor") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))))) (DoLet false false (PVar "diags") (EApp (EApp (EVar "analyzeFinish") (EVar "surface")) (EListLit))) (DoExpr (EIf (EFieldAccess (EVar "surface") "resolveClean") (EApp (EVar "Ok") (ETuple (EVar "graph") (EApp (EApp (EApp (EApp (EVar "JsonSingle") (EVar "entry")) (EVar "src")) (EVar "diags")) (EVar "raw")))) (EApp (EVar "Err") (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "cjSingleParts") (EVar "entry")) (EVar "src")) (EVar "raw")) (EVar "diags")))))))) (arm PWild () (EBlock (DoLet false false (PVar "buckets") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveLoadedBuckets") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EVar "allowInternal")) (EVar "trusted")) (EVar "entry")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "mods")) (EFieldAccess (EVar "graph") "fgModsD"))) (DoExpr (EIf (EApp (EVar "bucketsResolveRejected") (EVar "buckets")) (EBlock (DoLet false false (PTuple PWild (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckLoadedBuckets") (EVar "entry")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "mods")) (EFieldAccess (EVar "graph") "fgModsD")) (EVar "buckets"))) (DoExpr (EApp (EVar "Err") (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "cjGraphParts") (EVar "entry")) (EVar "stdlibDir")) (EVar "pairs")) (EVar "results")))))) (EApp (EVar "Ok") (ETuple (EVar "graph") (EApp (EApp (EApp (EVar "JsonGraph") (EVar "entry")) (EVar "stdlibDir")) (EVar "buckets"))))))))))))))))
(DTypeSig true "frontJsonAfterDrive" (TyFun (TyCon "JsonFront") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyFun (TyApp (TyCon "Option") (TyCon "Diag")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "CheckJson")) (TyCon "CheckJson")))))))))))
(DFunDef false "frontJsonAfterDrive" ((PVar "front") (PVar "rtD") (PVar "coreD") (PVar "mods") (PVar "modsD") (PVar "perMod") (PVar "refusal")) (EBlock (DoLet false false (PTuple (PVar "cj") (PVar "hasErr")) (EMatch (EVar "front") (arm (PCon "JsonSingle" (PVar "target") (PVar "src") (PVar "surface") (PVar "raw")) () (EApp (EApp (EApp (EApp (EVar "cjSingleParts") (EVar "target")) (EVar "src")) (EVar "raw")) (EBinOp "++" (EVar "surface") (EApp (EVar "tcHalfOfPerModule") (EVar "perMod"))))) (arm (PCon "JsonGraph" (PVar "target") (PVar "stdlibDir") (PVar "buckets")) () (EApp (EApp (EApp (EApp (EVar "cjGraphParts") (EVar "target")) (EVar "stdlibDir")) (EApp (EApp (EVar "map") (EVar "dropPathTriple")) (EVar "mods"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckDiagsFold") (EVar "rtD")) (EVar "coreD")) (EVar "mods")) (EVar "modsD")) (EVar "perMod")) (EVar "buckets")))))) (DoLet false false (PVar "entry") (EApp (EVar "jsonFrontEntry") (EVar "front"))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "Err") (EVar "cj")) (EMatch (EApp (EApp (EVar "mainRefusalJson") (EVar "entry")) (EVar "mods")) (arm (PCon "Some" (PVar "refused")) () (EApp (EVar "Err") (EVar "refused"))) (arm (PCon "None") () (EMatch (ETuple (EVar "refusal") (EVar "cj")) (arm (PTuple (PCon "Some" (PVar "d")) (PCon "CjParts" (PVar "key") (PVar "triples"))) () (EApp (EVar "Err") (EApp (EApp (EVar "CjParts") (EVar "key")) (EApp (EApp (EApp (EVar "cjFoldIntoFile") (EVar "key")) (EListLit (EVar "d"))) (EVar "triples"))))) (arm PWild () (EApp (EVar "Ok") (EVar "cj"))))))))))
(DTypeSig false "jsonFrontEntry" (TyFun (TyCon "JsonFront") (TyCon "String")))
(DFunDef false "jsonFrontEntry" ((PCon "JsonSingle" (PVar "target") PWild PWild PWild)) (EVar "target"))
(DFunDef false "jsonFrontEntry" ((PCon "JsonGraph" (PVar "target") PWild PWild)) (EVar "target"))
(DTypeSig false "mainRefusalJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "CheckJson"))))))
(DFunDef false "mainRefusalJson" ((PVar "entry") (PVar "mods")) (EMatch (EApp (EVar "splitLast") (EVar "mods")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple PWild (PTuple PWild PWild (PVar "decls")))) () (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EVar "CjParts") (EVar "entry")) (EListLit (ETuple (EVar "entry") (EApp (EVar "readFileSafe") (EVar "entry")) (EListLit (EVar "d"))))))) (EApp (EVar "mainEntryError") (EVar "decls"))))))
(DTypeSig true "writeDiagJson" (TyFun (TyCon "String") (TyFun (TyCon "CheckJson") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeDiagJson" ((PVar "path") (PVar "cj")) (EBlock (DoLet false false (PVar "key") (EMatch (EVar "cj") (arm (PCon "CjParts" (PVar "k") PWild) () (EVar "k")) (arm (PCon "CjRendered" PWild) () (ELit (LString ""))))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "path")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "key"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "ppCheckJson") (EVar "cj")))) (ELit (LString "")))) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not write the diagnostics envelope to ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))))
(DTypeSig true "readDiagJson" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "readDiagJson" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "i")) () (EMatch (EApp (EVar "parse") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "text"))) (arm (PCon "Ok" (PCon "JString" (PVar "key"))) () (EApp (EVar "Some") (ETuple (EVar "key") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "text"))) (EVar "text"))))) (arm PWild () (EVar "None"))))))))
(DTypeSig true "envelopeWithNotes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "envelopeWithNotes" (PWild (PList) (PVar "envelope")) (EVar "envelope"))
(DFunDef false "envelopeWithNotes" ((PVar "key") (PVar "notes") (PVar "envelope")) (EMatch (EApp (EVar "parse") (EVar "envelope")) (arm (PCon "Ok" (PCon "JObject" (PVar "members"))) () (EApp (EVar "stringify") (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EApp (EApp (EVar "filesWithNotes") (EVar "key")) (EVar "notes"))) (EApp (EVar "toList") (EVar "members"))))))) (arm PWild () (EVar "envelope"))))
(DTypeSig false "filesWithNotes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyTuple (TyCon "String") (TyCon "Json")) (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "filesWithNotes" ((PVar "key") (PVar "notes") (PTuple (PLit (LString "files")) (PCon "JArray" (PVar "files")))) (ETuple (ELit (LString "files")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "foldNotesInto") (EVar "key")) (EVar "notes")) (EApp (EVar "toList") (EVar "files")))))))
(DFunDef false "filesWithNotes" (PWild PWild (PVar "member")) (EVar "member"))
(DTypeSig false "foldNotesInto" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "foldNotesInto" (PWild PWild (PList)) (EListLit))
(DFunDef false "foldNotesInto" ((PVar "key") (PVar "notes") (PCons (PVar "file") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "fileWithNotes") (EVar "key")) (EVar "notes")) (EVar "file")) (arm (PCon "Some" (PVar "folded")) () (EBinOp "::" (EVar "folded") (EVar "rest"))) (arm (PCon "None") () (EBinOp "::" (EVar "file") (EApp (EApp (EApp (EVar "foldNotesInto") (EVar "key")) (EVar "notes")) (EVar "rest"))))))
(DTypeSig false "fileWithNotes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "fileWithNotes" ((PVar "key") (PVar "notes") (PCon "JObject" (PVar "members"))) (EMatch (EApp (EVar "toList") (EVar "members")) (arm (PList (PTuple (PLit (LString "file")) (PCon "JString" (PVar "p"))) (PTuple (PLit (LString "diagnostics")) (PCon "JArray" (PVar "ds")))) () (EIf (EBinOp "==" (EVar "p") (EVar "key")) (EApp (EVar "Some") (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "p"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EBinOp "++" (EApp (EVar "toList") (EVar "ds")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "cjDiagnostic") (EVar "p")) (ELit (LString "")))) (EVar "notes")))))))))) (EVar "None"))) (arm PWild () (EVar "None"))))
(DFunDef false "fileWithNotes" (PWild PWild PWild) (EVar "None"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("types" "typecheck") ((mem "TcDiag" false) (mem "setStdlibOwnership" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "parse" false) (mem "stringify" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseLocated" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugarIn" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "desugaredPreludeKey" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "internalGuardFor" false) (mem "resolveModulesErrorsByFile" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "CheckJson" true) (mem "Diag" true) (mem "Severity" true) (mem "analyzeFinish" false) (mem "analyzeSurface" false) (mem "bucketsResolveRejected" false) (mem "cjDiagnostic" false) (mem "cjFoldIntoFile" false) (mem "cjGraphParts" false) (mem "cjLoadFailure" false) (mem "cjSingleParts" false) (mem "ppCheckJson" false) (mem "readFileSafe" false) (mem "resolveLoadedBuckets" false) (mem "tcHalfOfPerModule" false) (mem "typecheckDiagsFold" false) (mem "typecheckLoadedBuckets" false) (mem "hintResErrorPairs" false) (mem "mainEntryError" false) (mem "ppDiagCliLines" false) (mem "ppDiagCliSrc" false) (mem "ppMainEntryError" false) (mem "ppResolveErrorsByFile" false) (mem "parseErrHelpFix" false) (mem "parseErrCode" false) (mem "srcLinesArr" false) (mem "stdlibExportsReader" false) (mem "surfaceErrors" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" true) (mem "dropPathTriple" false) (mem "entrySearchRoots" false) (mem "loadProgramFilesLocatedE" false) (mem "modIdToPath" false) (mem "projectTrustedMods" false) (mem "readSource" false) (mem "stdlibOwnership" false) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "joinNl" false) (mem "splitLast" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DTypeSig true "cliStdlibExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "cliStdlibExports" ((PVar "stdlibDir") (PVar "names")) (EApp (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir")) (EVar "names")))
(DTypeSig true "ppParseError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "ppParseError" ((PVar "src") (PVar "file") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EApp (EVar "parseErrorCol") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "h") (PVar "fx")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "h")) (EVar "fx"))))))
(DTypeSig true "moduleLoadErrText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "e"))) (EApp (EApp (EApp (EVar "ppParseError") (EVar "msrc")) (EVar "mpath")) (EVar "e")))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadCycle" (PVar "lmsg") (PVar "cpath") (PVar "csite"))) (EMatch (EVar "csite") (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PTuple (PVar "csrc") (PVar "loc"))) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "csrc")) (EVar "cpath")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "lmsg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))
(DFunDef false "moduleLoadErrText" ((PVar "tsrc") (PVar "target") (PVar "stdlibDir") (PCon "LoadMsg" (PVar "lmsg"))) (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EVar "lmsg") (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "tsrc"))) (arm (PCon "None") () (EVar "msg")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "msg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))))))
(DTypeSig true "frontGateEnv" (TyCon "String"))
(DFunDef false "frontGateEnv" () (ELit (LString "MEDAKA_FRONT_GATE")))
(DTypeSig true "frontGateAssignment" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "frontGateAssignment" ((PCon "True")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "frontGateEnv"))) (ELit (LString "=allow-internal"))))
(DFunDef false "frontGateAssignment" ((PCon "False")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "frontGateEnv"))) (ELit (LString "=1"))))
(DTypeSig true "frontGateOfEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Bool")))))
(DFunDef false "frontGateOfEnv" (PWild) (EMatch (EApp (EVar "getEnv") (EVar "frontGateEnv")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "None")) (arm (PCon "Some" (PLit (LString "allow-internal"))) () (EApp (EVar "Some") (EVar "True"))) (arm (PCon "Some" PWild) () (EApp (EVar "Some") (EVar "False")))))
(DData Public "FrontGraph" () ((variant "FrontGraph" (ConNamed (field "fgRoots" (TyApp (TyCon "List") (TyCon "String"))) (field "fgMods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (field "fgRuntimeD" (TyApp (TyCon "List") (TyCon "Decl"))) (field "fgCoreD" (TyApp (TyCon "List") (TyCon "Decl"))) (field "fgModsD" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))) ())
(DTypeSig true "frontGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "FrontGraph")))))))))
(DFunDef false "frontGate" ((PVar "allowInternal") (PVar "stdlibDir") (PVar "rsrc") (PVar "csrc") (PVar "entry")) (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "entry"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "loadRefusal") (EVar "stdlibDir")) (EVar "entry")) (EVar "lerr")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EMethodRef "map") (EVar "dropPathTriple")) (EVar "mods"))) (DoLet false false (PVar "graph") (EApp (EApp (EApp (EApp (EVar "frontGraphOf") (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "mods"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "entry")) (EVar "roots")) (EVar "stdlibDir")) (EVar "pairs"))) (DoLet false false (PVar "resolved") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveRefusal") (EVar "allowInternal")) (EVar "stdlibDir")) (EVar "trusted")) (EVar "rsrc")) (EVar "csrc")) (EVar "entry")) (EVar "graph"))) (DoExpr (EMatch (EVar "resolved") (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "mainRefusal") (EVar "entry")) (EVar "pairs")) (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "graph")))))))))))))
(DTypeSig false "frontGraphOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "FrontGraph"))))))
(DFunDef false "frontGraphOf" ((PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "mods")) (ERecordCreate "FrontGraph" ((fa "fgRoots" (EVar "roots")) (fa "fgMods" (EVar "mods")) (fa "fgRuntimeD" (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (fa "fgCoreD" (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (fa "fgModsD" (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "mid") PWild (PVar "p"))) (ETuple (EVar "mid") (EApp (EApp (EVar "desugarIn") (EVar "mid")) (EVar "p"))))) (EVar "mods"))))))
(DTypeSig false "loadRefusal" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "loadRefusal" ((PVar "stdlibDir") (PVar "entry") (PVar "lerr")) (EMatch (EApp (EVar "readSource") (EVar "entry")) (arm (PCon "Err" (PVar "e")) () (EVar "e")) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "entry")) (EVar "e"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "entry")) (EVar "stdlibDir")) (EVar "lerr")))))))
(DTypeSig false "resolveRefusal" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "FrontGraph") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))))))
(DFunDef false "resolveRefusal" ((PVar "allowInternal") (PVar "stdlibDir") (PVar "trusted") (PVar "rsrc") (PVar "csrc") (PVar "entry") (PVar "g")) (EBlock (DoLet false false (PVar "trees") (ETuple (EFieldAccess (EVar "g") "fgMods") (EFieldAccess (EVar "g") "fgModsD"))) (DoExpr (EMatch (EVar "trees") (arm (PTuple (PList (PTuple (PVar "mid") PWild (PVar "raw"))) (PList (PTuple PWild (PVar "desugared")))) () (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "surfaceErrors") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EFieldAccess (EVar "g") "fgRuntimeD")) (EFieldAccess (EVar "g") "fgCoreD")) (EVar "raw")) (EVar "desugared")) (EApp (EVar "internalGuardFor") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "None")) (arm PWild () (EBlock (DoLet false false (PVar "lines") (EApp (EVar "srcLinesArr") (EApp (EVar "entrySource") (EVar "entry")))) (DoExpr (EApp (EVar "Some") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EVar "lines")) (EVar "entry"))) (EVar "errs"))))))))))) (arm PWild () (EBlock (DoLet false false (PVar "text") (EApp (EVar "ppResolveErrorsByFile") (EApp (EApp (EVar "hintResErrorPairs") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsByFile") (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EFieldAccess (EVar "g") "fgMods"))) (EVar "allowInternal")) (EVar "trusted")) (EApp (EVar "Some") (ETuple (EApp (EVar "desugaredPreludeKey") (EVar "rsrc")) (EApp (EVar "desugaredPreludeKey") (EVar "csrc"))))) (EFieldAccess (EVar "g") "fgRuntimeD")) (EFieldAccess (EVar "g") "fgCoreD")) (EFieldAccess (EVar "g") "fgModsD"))))) (DoExpr (EIf (EBinOp "==" (EVar "text") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "text"))))))))))
(DTypeSig false "mainRefusal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "mainRefusal" ((PVar "entry") (PVar "pairs")) (EMatch (EApp (EVar "splitLast") (EVar "pairs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple PWild (PTuple PWild (PVar "decls")))) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EVar "ppMainEntryError") (EApp (EVar "entrySource") (EVar "entry"))) (EVar "entry")) (EVar "d")))) (EApp (EVar "mainEntryError") (EVar "decls"))))))
(DTypeSig false "entrySource" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "entrySource" ((PVar "entry")) (EMatch (EApp (EVar "readFile") (EVar "entry")) (arm (PCon "Ok" (PVar "src")) () (EVar "src")) (arm (PCon "Err" PWild) () (ELit (LString "")))))
(DData Public "GateAsk" () ((variant "GateAsk" (ConNamed (field "askAllowInternal" (TyCon "Bool")) (field "askDiagJson" (TyCon "Bool"))))) ())
(DTypeSig true "diagJsonEnv" (TyCon "String"))
(DFunDef false "diagJsonEnv" () (ELit (LString "MEDAKA_DIAG_JSON")))
(DTypeSig true "gateAckEnv" (TyCon "String"))
(DFunDef false "gateAckEnv" () (ELit (LString "MEDAKA_FRONT_GATE_ACK")))
(DTypeSig true "gateAssignments" (TyFun (TyCon "GateAsk") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "gateAssignments" ((PVar "ask") (PVar "diagPath") (PVar "ackPath")) (EListLit (EApp (EVar "frontGateAssignment") (EFieldAccess (EVar "ask") "askAllowInternal")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "diagJsonEnv"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EIf (EFieldAccess (EVar "ask") "askDiagJson") (EVar "diagPath") (ELit (LString ""))))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "gateAckEnv"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EVar "ackPath"))) (ELit (LString "")))))
(DTypeSig true "noGateAssignments" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "noGateAssignments" () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "frontGateEnv"))) (ELit (LString "="))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "diagJsonEnv"))) (ELit (LString "="))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "gateAckEnv"))) (ELit (LString "=")))))
(DTypeSig true "writeGateAck" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "writeGateAck" (PWild) (EMatch (EApp (EVar "getEnv") (EVar "gateAckEnv")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PLit (LString ""))) () (ELit LUnit)) (arm (PCon "Some" (PVar "path")) () (EMatch (EApp (EApp (EVar "writeFile") (EVar "path")) (ELit (LString "ran\n"))) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not write the gate acknowledgement to ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))))
(DTypeSig true "diagJsonPathOfEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "diagJsonPathOfEnv" (PWild) (EMatch (EApp (EVar "getEnv") (EVar "diagJsonEnv")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PLit (LString ""))) () (EVar "None")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "Some") (EVar "p")))))
(DData Public "JsonFront" () ((variant "JsonSingle" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyCon "Decl")))) (variant "JsonGraph" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))) ())
(DTypeSig true "frontGateJson" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "CheckJson")) (TyTuple (TyCon "FrontGraph") (TyCon "JsonFront"))))))))))
(DFunDef false "frontGateJson" ((PVar "allowInternal") (PVar "stdlibDir") (PVar "rsrc") (PVar "csrc") (PVar "entry")) (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "entry"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EVar "cjLoadFailure") (EVar "entry")) (EApp (EVar "readFileSafe") (EVar "entry"))) (EVar "stdlibDir")) (EVar "lerr")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EMethodRef "map") (EVar "dropPathTriple")) (EVar "mods"))) (DoLet false false (PVar "graph") (EApp (EApp (EApp (EApp (EVar "frontGraphOf") (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "mods"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "entry")) (EVar "roots")) (EVar "stdlibDir")) (EVar "pairs"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "entry")) (EVar "roots")) (EVar "stdlibDir")) (EVar "pairs"))) (DoLet false false PWild (EApp (EApp (EVar "setStdlibOwnership") (EVar "flatStdlib")) (EVar "ownedStdlib"))) (DoExpr (EMatch (EVar "mods") (arm (PList (PTuple (PVar "mid") PWild (PVar "raw"))) () (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "entry"))) (DoLet false false (PVar "surface") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeSurface") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EVar "mid")) (EVar "rsrc")) (EVar "csrc")) (EVar "raw")) (EApp (EVar "internalGuardFor") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))))) (DoLet false false (PVar "diags") (EApp (EApp (EVar "analyzeFinish") (EVar "surface")) (EListLit))) (DoExpr (EIf (EFieldAccess (EVar "surface") "resolveClean") (EApp (EVar "Ok") (ETuple (EVar "graph") (EApp (EApp (EApp (EApp (EVar "JsonSingle") (EVar "entry")) (EVar "src")) (EVar "diags")) (EVar "raw")))) (EApp (EVar "Err") (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "cjSingleParts") (EVar "entry")) (EVar "src")) (EVar "raw")) (EVar "diags")))))))) (arm PWild () (EBlock (DoLet false false (PVar "buckets") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveLoadedBuckets") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EVar "allowInternal")) (EVar "trusted")) (EVar "entry")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "mods")) (EFieldAccess (EVar "graph") "fgModsD"))) (DoExpr (EIf (EApp (EVar "bucketsResolveRejected") (EVar "buckets")) (EBlock (DoLet false false (PTuple PWild (PVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckLoadedBuckets") (EVar "entry")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "mods")) (EFieldAccess (EVar "graph") "fgModsD")) (EVar "buckets"))) (DoExpr (EApp (EVar "Err") (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "cjGraphParts") (EVar "entry")) (EVar "stdlibDir")) (EVar "pairs")) (EVar "results")))))) (EApp (EVar "Ok") (ETuple (EVar "graph") (EApp (EApp (EApp (EVar "JsonGraph") (EVar "entry")) (EVar "stdlibDir")) (EVar "buckets"))))))))))))))))
(DTypeSig true "frontJsonAfterDrive" (TyFun (TyCon "JsonFront") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyFun (TyApp (TyCon "Option") (TyCon "Diag")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "CheckJson")) (TyCon "CheckJson")))))))))))
(DFunDef false "frontJsonAfterDrive" ((PVar "front") (PVar "rtD") (PVar "coreD") (PVar "mods") (PVar "modsD") (PVar "perMod") (PVar "refusal")) (EBlock (DoLet false false (PTuple (PVar "cj") (PVar "hasErr")) (EMatch (EVar "front") (arm (PCon "JsonSingle" (PVar "target") (PVar "src") (PVar "surface") (PVar "raw")) () (EApp (EApp (EApp (EApp (EVar "cjSingleParts") (EVar "target")) (EVar "src")) (EVar "raw")) (EBinOp "++" (EVar "surface") (EApp (EVar "tcHalfOfPerModule") (EVar "perMod"))))) (arm (PCon "JsonGraph" (PVar "target") (PVar "stdlibDir") (PVar "buckets")) () (EApp (EApp (EApp (EApp (EVar "cjGraphParts") (EVar "target")) (EVar "stdlibDir")) (EApp (EApp (EMethodRef "map") (EVar "dropPathTriple")) (EVar "mods"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckDiagsFold") (EVar "rtD")) (EVar "coreD")) (EVar "mods")) (EVar "modsD")) (EVar "perMod")) (EVar "buckets")))))) (DoLet false false (PVar "entry") (EApp (EVar "jsonFrontEntry") (EVar "front"))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "Err") (EVar "cj")) (EMatch (EApp (EApp (EVar "mainRefusalJson") (EVar "entry")) (EVar "mods")) (arm (PCon "Some" (PVar "refused")) () (EApp (EVar "Err") (EVar "refused"))) (arm (PCon "None") () (EMatch (ETuple (EVar "refusal") (EVar "cj")) (arm (PTuple (PCon "Some" (PVar "d")) (PCon "CjParts" (PVar "key") (PVar "triples"))) () (EApp (EVar "Err") (EApp (EApp (EVar "CjParts") (EVar "key")) (EApp (EApp (EApp (EVar "cjFoldIntoFile") (EVar "key")) (EListLit (EVar "d"))) (EVar "triples"))))) (arm PWild () (EApp (EVar "Ok") (EVar "cj"))))))))))
(DTypeSig false "jsonFrontEntry" (TyFun (TyCon "JsonFront") (TyCon "String")))
(DFunDef false "jsonFrontEntry" ((PCon "JsonSingle" (PVar "target") PWild PWild PWild)) (EVar "target"))
(DFunDef false "jsonFrontEntry" ((PCon "JsonGraph" (PVar "target") PWild PWild)) (EVar "target"))
(DTypeSig false "mainRefusalJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "CheckJson"))))))
(DFunDef false "mainRefusalJson" ((PVar "entry") (PVar "mods")) (EMatch (EApp (EVar "splitLast") (EVar "mods")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple PWild (PTuple PWild PWild (PVar "decls")))) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EVar "CjParts") (EVar "entry")) (EListLit (ETuple (EVar "entry") (EApp (EVar "readFileSafe") (EVar "entry")) (EListLit (EVar "d"))))))) (EApp (EVar "mainEntryError") (EVar "decls"))))))
(DTypeSig true "writeDiagJson" (TyFun (TyCon "String") (TyFun (TyCon "CheckJson") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeDiagJson" ((PVar "path") (PVar "cj")) (EBlock (DoLet false false (PVar "key") (EMatch (EVar "cj") (arm (PCon "CjParts" (PVar "k") PWild) () (EVar "k")) (arm (PCon "CjRendered" PWild) () (ELit (LString ""))))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "path")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "stringify") (EApp (EVar "JString") (EVar "key"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "ppCheckJson") (EVar "cj")))) (ELit (LString "")))) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not write the diagnostics envelope to ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))))
(DTypeSig true "readDiagJson" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "readDiagJson" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "text")) () (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "i")) () (EMatch (EApp (EVar "parse") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "text"))) (arm (PCon "Ok" (PCon "JString" (PVar "key"))) () (EApp (EVar "Some") (ETuple (EVar "key") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "text"))) (EVar "text"))))) (arm PWild () (EVar "None"))))))))
(DTypeSig true "envelopeWithNotes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "envelopeWithNotes" (PWild (PList) (PVar "envelope")) (EVar "envelope"))
(DFunDef false "envelopeWithNotes" ((PVar "key") (PVar "notes") (PVar "envelope")) (EMatch (EApp (EVar "parse") (EVar "envelope")) (arm (PCon "Ok" (PCon "JObject" (PVar "members"))) () (EApp (EVar "stringify") (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "filesWithNotes") (EVar "key")) (EVar "notes"))) (EApp (EMethodRef "toList") (EVar "members"))))))) (arm PWild () (EVar "envelope"))))
(DTypeSig false "filesWithNotes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyTuple (TyCon "String") (TyCon "Json")) (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "filesWithNotes" ((PVar "key") (PVar "notes") (PTuple (PLit (LString "files")) (PCon "JArray" (PVar "files")))) (ETuple (ELit (LString "files")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "foldNotesInto") (EVar "key")) (EVar "notes")) (EApp (EMethodRef "toList") (EVar "files")))))))
(DFunDef false "filesWithNotes" (PWild PWild (PVar "member")) (EVar "member"))
(DTypeSig false "foldNotesInto" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "foldNotesInto" (PWild PWild (PList)) (EListLit))
(DFunDef false "foldNotesInto" ((PVar "key") (PVar "notes") (PCons (PVar "file") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "fileWithNotes") (EVar "key")) (EVar "notes")) (EVar "file")) (arm (PCon "Some" (PVar "folded")) () (EBinOp "::" (EVar "folded") (EVar "rest"))) (arm (PCon "None") () (EBinOp "::" (EVar "file") (EApp (EApp (EApp (EVar "foldNotesInto") (EVar "key")) (EVar "notes")) (EVar "rest"))))))
(DTypeSig false "fileWithNotes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Json"))))))
(DFunDef false "fileWithNotes" ((PVar "key") (PVar "notes") (PCon "JObject" (PVar "members"))) (EMatch (EApp (EMethodRef "toList") (EVar "members")) (arm (PList (PTuple (PLit (LString "file")) (PCon "JString" (PVar "p"))) (PTuple (PLit (LString "diagnostics")) (PCon "JArray" (PVar "ds")))) () (EIf (EBinOp "==" (EVar "p") (EVar "key")) (EApp (EVar "Some") (EApp (EVar "JObject") (EApp (EVar "arrayFromList") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "p"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EBinOp "++" (EApp (EMethodRef "toList") (EVar "ds")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "cjDiagnostic") (EVar "p")) (ELit (LString "")))) (EVar "notes")))))))))) (EVar "None"))) (arm PWild () (EVar "None"))))
(DFunDef false "fileWithNotes" (PWild PWild PWild) (EVar "None"))
