# META
source_lines=273
stages=DESUGAR,MARK
# SOURCE
-- compiler/driver/front_gate.mdk — the front-end error renderers the CLI verbs
-- share, and `build`'s front-end gate, which the `medaka_emitter` child runs
-- when the `build` verb asks for it (`frontGateEnv`).  Nothing here reads the
-- process environment except `frontGateOfEnv`: the stdlib directory is a
-- parameter.  So a caller that is not the CLI dispatcher (the emitter child)
-- can import this module without `medaka_cli.mdk`.

import frontend.ast.{Decl, Loc(..)}
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
  Diag(..),
  Severity(..),
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
  unknownModuleIdOf,
  findImportLoc,
  availableModulesHint,
}
import support.path.{dirOf}
import support.util.{contains, joinNl, splitLast}

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
      let graph = FrontGraph {
        fgRoots = roots,
        fgMods = mods,
        fgRuntimeD = desugaredPrelude rsrc,
        fgCoreD = desugaredPrelude csrc,
        fgModsD = map ((mid, p) => (mid, desugarIn mid p)) pairs,
      }
      let trusted = projectTrustedMods entry roots stdlibDir pairs
      let resolved =
        resolveRefusal allowInternal stdlibDir trusted rsrc csrc entry graph
      match resolved
        Some msg => Err msg
        None => match mainRefusal entry pairs
          Some msg => Err msg
          None => Ok graph

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
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseLocated" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugarIn" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "desugaredPreludeKey" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "internalGuardFor" false) (mem "resolveModulesErrorsByFile" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "hintResErrorPairs" false) (mem "mainEntryError" false) (mem "ppDiagCliLines" false) (mem "ppDiagCliSrc" false) (mem "ppMainEntryError" false) (mem "ppResolveErrorsByFile" false) (mem "parseErrHelpFix" false) (mem "parseErrCode" false) (mem "srcLinesArr" false) (mem "stdlibExportsReader" false) (mem "surfaceErrors" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" true) (mem "dropPathTriple" false) (mem "entrySearchRoots" false) (mem "loadProgramFilesLocatedE" false) (mem "modIdToPath" false) (mem "projectTrustedMods" false) (mem "readSource" false) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "joinNl" false) (mem "splitLast" false))))
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
(DFunDef false "frontGate" ((PVar "allowInternal") (PVar "stdlibDir") (PVar "rsrc") (PVar "csrc") (PVar "entry")) (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "entry"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "loadRefusal") (EVar "stdlibDir")) (EVar "entry")) (EVar "lerr")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "map") (EVar "dropPathTriple")) (EVar "mods"))) (DoLet false false (PVar "graph") (ERecordCreate "FrontGraph" ((fa "fgRoots" (EVar "roots")) (fa "fgMods" (EVar "mods")) (fa "fgRuntimeD" (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (fa "fgCoreD" (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (fa "fgModsD" (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EApp (EVar "desugarIn") (EVar "mid")) (EVar "p"))))) (EVar "pairs")))))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "entry")) (EVar "roots")) (EVar "stdlibDir")) (EVar "pairs"))) (DoLet false false (PVar "resolved") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveRefusal") (EVar "allowInternal")) (EVar "stdlibDir")) (EVar "trusted")) (EVar "rsrc")) (EVar "csrc")) (EVar "entry")) (EVar "graph"))) (DoExpr (EMatch (EVar "resolved") (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "mainRefusal") (EVar "entry")) (EVar "pairs")) (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "graph")))))))))))))
(DTypeSig false "loadRefusal" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "loadRefusal" ((PVar "stdlibDir") (PVar "entry") (PVar "lerr")) (EMatch (EApp (EVar "readSource") (EVar "entry")) (arm (PCon "Err" (PVar "e")) () (EVar "e")) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "entry")) (EVar "e"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "entry")) (EVar "stdlibDir")) (EVar "lerr")))))))
(DTypeSig false "resolveRefusal" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "FrontGraph") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))))))
(DFunDef false "resolveRefusal" ((PVar "allowInternal") (PVar "stdlibDir") (PVar "trusted") (PVar "rsrc") (PVar "csrc") (PVar "entry") (PVar "g")) (EBlock (DoLet false false (PVar "trees") (ETuple (EFieldAccess (EVar "g") "fgMods") (EFieldAccess (EVar "g") "fgModsD"))) (DoExpr (EMatch (EVar "trees") (arm (PTuple (PList (PTuple (PVar "mid") PWild (PVar "raw"))) (PList (PTuple PWild (PVar "desugared")))) () (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "surfaceErrors") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EFieldAccess (EVar "g") "fgRuntimeD")) (EFieldAccess (EVar "g") "fgCoreD")) (EVar "raw")) (EVar "desugared")) (EApp (EVar "internalGuardFor") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "None")) (arm PWild () (EBlock (DoLet false false (PVar "lines") (EApp (EVar "srcLinesArr") (EApp (EVar "entrySource") (EVar "entry")))) (DoExpr (EApp (EVar "Some") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EVar "lines")) (EVar "entry"))) (EVar "errs"))))))))))) (arm PWild () (EBlock (DoLet false false (PVar "text") (EApp (EVar "ppResolveErrorsByFile") (EApp (EApp (EVar "hintResErrorPairs") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsByFile") (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EFieldAccess (EVar "g") "fgMods"))) (EVar "allowInternal")) (EVar "trusted")) (EApp (EVar "Some") (ETuple (EApp (EVar "desugaredPreludeKey") (EVar "rsrc")) (EApp (EVar "desugaredPreludeKey") (EVar "csrc"))))) (EFieldAccess (EVar "g") "fgRuntimeD")) (EFieldAccess (EVar "g") "fgCoreD")) (EFieldAccess (EVar "g") "fgModsD"))))) (DoExpr (EIf (EBinOp "==" (EVar "text") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "text"))))))))))
(DTypeSig false "mainRefusal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "mainRefusal" ((PVar "entry") (PVar "pairs")) (EMatch (EApp (EVar "splitLast") (EVar "pairs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple PWild (PTuple PWild (PVar "decls")))) () (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EVar "ppMainEntryError") (EApp (EVar "entrySource") (EVar "entry"))) (EVar "entry")) (EVar "d")))) (EApp (EVar "mainEntryError") (EVar "decls"))))))
(DTypeSig false "entrySource" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "entrySource" ((PVar "entry")) (EMatch (EApp (EVar "readFile") (EVar "entry")) (arm (PCon "Ok" (PVar "src")) () (EVar "src")) (arm (PCon "Err" PWild) () (ELit (LString "")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseLocated" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugarIn" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "desugaredPreludeKey" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "internalGuardFor" false) (mem "resolveModulesErrorsByFile" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "hintResErrorPairs" false) (mem "mainEntryError" false) (mem "ppDiagCliLines" false) (mem "ppDiagCliSrc" false) (mem "ppMainEntryError" false) (mem "ppResolveErrorsByFile" false) (mem "parseErrHelpFix" false) (mem "parseErrCode" false) (mem "srcLinesArr" false) (mem "stdlibExportsReader" false) (mem "surfaceErrors" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" true) (mem "dropPathTriple" false) (mem "entrySearchRoots" false) (mem "loadProgramFilesLocatedE" false) (mem "modIdToPath" false) (mem "projectTrustedMods" false) (mem "readSource" false) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "joinNl" false) (mem "splitLast" false))))
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
(DFunDef false "frontGate" ((PVar "allowInternal") (PVar "stdlibDir") (PVar "rsrc") (PVar "csrc") (PVar "entry")) (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "entry"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "loadRefusal") (EVar "stdlibDir")) (EVar "entry")) (EVar "lerr")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EMethodRef "map") (EVar "dropPathTriple")) (EVar "mods"))) (DoLet false false (PVar "graph") (ERecordCreate "FrontGraph" ((fa "fgRoots" (EVar "roots")) (fa "fgMods" (EVar "mods")) (fa "fgRuntimeD" (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (fa "fgCoreD" (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (fa "fgModsD" (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EApp (EVar "desugarIn") (EVar "mid")) (EVar "p"))))) (EVar "pairs")))))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "entry")) (EVar "roots")) (EVar "stdlibDir")) (EVar "pairs"))) (DoLet false false (PVar "resolved") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveRefusal") (EVar "allowInternal")) (EVar "stdlibDir")) (EVar "trusted")) (EVar "rsrc")) (EVar "csrc")) (EVar "entry")) (EVar "graph"))) (DoExpr (EMatch (EVar "resolved") (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "mainRefusal") (EVar "entry")) (EVar "pairs")) (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "None") () (EApp (EVar "Ok") (EVar "graph")))))))))))))
(DTypeSig false "loadRefusal" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "loadRefusal" ((PVar "stdlibDir") (PVar "entry") (PVar "lerr")) (EMatch (EApp (EVar "readSource") (EVar "entry")) (arm (PCon "Err" (PVar "e")) () (EVar "e")) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "entry")) (EVar "e"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "entry")) (EVar "stdlibDir")) (EVar "lerr")))))))
(DTypeSig false "resolveRefusal" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "FrontGraph") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))))))
(DFunDef false "resolveRefusal" ((PVar "allowInternal") (PVar "stdlibDir") (PVar "trusted") (PVar "rsrc") (PVar "csrc") (PVar "entry") (PVar "g")) (EBlock (DoLet false false (PVar "trees") (ETuple (EFieldAccess (EVar "g") "fgMods") (EFieldAccess (EVar "g") "fgModsD"))) (DoExpr (EMatch (EVar "trees") (arm (PTuple (PList (PTuple (PVar "mid") PWild (PVar "raw"))) (PList (PTuple PWild (PVar "desugared")))) () (EBlock (DoLet false false (PVar "errs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "surfaceErrors") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EFieldAccess (EVar "g") "fgRuntimeD")) (EFieldAccess (EVar "g") "fgCoreD")) (EVar "raw")) (EVar "desugared")) (EApp (EVar "internalGuardFor") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "None")) (arm PWild () (EBlock (DoLet false false (PVar "lines") (EApp (EVar "srcLinesArr") (EApp (EVar "entrySource") (EVar "entry")))) (DoExpr (EApp (EVar "Some") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EVar "lines")) (EVar "entry"))) (EVar "errs"))))))))))) (arm PWild () (EBlock (DoLet false false (PVar "text") (EApp (EVar "ppResolveErrorsByFile") (EApp (EApp (EVar "hintResErrorPairs") (EApp (EVar "cliStdlibExports") (EVar "stdlibDir"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsByFile") (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EFieldAccess (EVar "g") "fgMods"))) (EVar "allowInternal")) (EVar "trusted")) (EApp (EVar "Some") (ETuple (EApp (EVar "desugaredPreludeKey") (EVar "rsrc")) (EApp (EVar "desugaredPreludeKey") (EVar "csrc"))))) (EFieldAccess (EVar "g") "fgRuntimeD")) (EFieldAccess (EVar "g") "fgCoreD")) (EFieldAccess (EVar "g") "fgModsD"))))) (DoExpr (EIf (EBinOp "==" (EVar "text") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "text"))))))))))
(DTypeSig false "mainRefusal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "mainRefusal" ((PVar "entry") (PVar "pairs")) (EMatch (EApp (EVar "splitLast") (EVar "pairs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple PWild (PTuple PWild (PVar "decls")))) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EVar "ppMainEntryError") (EApp (EVar "entrySource") (EVar "entry"))) (EVar "entry")) (EVar "d")))) (EApp (EVar "mainEntryError") (EVar "decls"))))))
(DTypeSig false "entrySource" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "entrySource" ((PVar "entry")) (EMatch (EApp (EVar "readFile") (EVar "entry")) (arm (PCon "Ok" (PVar "src")) () (EVar "src")) (arm (PCon "Err" PWild) () (ELit (LString "")))))
