# META
source_lines=110
stages=DESUGAR,MARK
# SOURCE
-- compiler/driver/front_gate.mdk — the front-end error renderers the CLI verbs
-- and the `build` parent share.  Each takes the source text and the file it was
-- read from, and none reads the process environment: the stdlib directory is a
-- parameter.  So a caller that is not the CLI dispatcher (the emitter child)
-- can import this module without `medaka_cli.mdk`.

import frontend.ast.{Loc(..)}
import frontend.parser.{
  parseLocated,
  ParseError,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
}
import driver.diagnostics.{
  Diag(..),
  Severity(..),
  ppDiagCliSrc,
  parseErrHelpFix,
  parseErrCode,
  stdlibExportsReader,
}
import driver.loader.{
  LoadError(..),
  unknownModuleIdOf,
  findImportLoc,
  availableModulesHint,
}

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
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseLocated" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "ppDiagCliSrc" false) (mem "parseErrHelpFix" false) (mem "parseErrCode" false) (mem "stdlibExportsReader" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" true) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false))))
(DTypeSig true "cliStdlibExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "cliStdlibExports" ((PVar "stdlibDir") (PVar "names")) (EApp (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir")) (EVar "names")))
(DTypeSig true "ppParseError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "ppParseError" ((PVar "src") (PVar "file") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EApp (EVar "parseErrorCol") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "h") (PVar "fx")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "h")) (EVar "fx"))))))
(DTypeSig true "moduleLoadErrText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "e"))) (EApp (EApp (EApp (EVar "ppParseError") (EVar "msrc")) (EVar "mpath")) (EVar "e")))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadCycle" (PVar "lmsg") (PVar "cpath") (PVar "csite"))) (EMatch (EVar "csite") (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PTuple (PVar "csrc") (PVar "loc"))) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "csrc")) (EVar "cpath")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "lmsg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))
(DFunDef false "moduleLoadErrText" ((PVar "tsrc") (PVar "target") (PVar "stdlibDir") (PCon "LoadMsg" (PVar "lmsg"))) (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EVar "lmsg") (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "tsrc"))) (arm (PCon "None") () (EVar "msg")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "msg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseLocated" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "ppDiagCliSrc" false) (mem "parseErrHelpFix" false) (mem "parseErrCode" false) (mem "stdlibExportsReader" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" true) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false))))
(DTypeSig true "cliStdlibExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "cliStdlibExports" ((PVar "stdlibDir") (PVar "names")) (EApp (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir")) (EVar "names")))
(DTypeSig true "ppParseError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "ppParseError" ((PVar "src") (PVar "file") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EApp (EVar "parseErrorCol") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "h") (PVar "fx")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "h")) (EVar "fx"))))))
(DTypeSig true "moduleLoadErrText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "e"))) (EApp (EApp (EApp (EVar "ppParseError") (EVar "msrc")) (EVar "mpath")) (EVar "e")))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadCycle" (PVar "lmsg") (PVar "cpath") (PVar "csite"))) (EMatch (EVar "csite") (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PTuple (PVar "csrc") (PVar "loc"))) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "csrc")) (EVar "cpath")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "lmsg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))
(DFunDef false "moduleLoadErrText" ((PVar "tsrc") (PVar "target") (PVar "stdlibDir") (PCon "LoadMsg" (PVar "lmsg"))) (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EVar "lmsg") (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "tsrc"))) (arm (PCon "None") () (EVar "msg")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "msg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))))))
