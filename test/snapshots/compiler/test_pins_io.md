# META
source_lines=101
stages=DESUGAR,MARK
# SOURCE
-- Filesystem context for the typed known-red ledger. The pure schema lives in
-- tools.test_pins; this module chooses one project, canonicalizes both sides
-- of every path comparison, and refuses rows whose file no longer exists.

import driver.loader.{findProjectRoot}
import fs.{isFile}
import support.path.{dirOf, joinPath}
import support.util.{contains, filterList}
import tools.test_pins.{TestPin, parsePins}
import string.{drop, startsWith}

public export data PinContext = PinContext {
  contextRoot : String,
  contextFile : String,
  contextPins : List TestPin,
}

ledgerName : String
ledgerName = "medaka-test-pins.toml"

-- Load the one ledger governing a target. The nearest project manifest wins;
-- without one, the target's directory is an explicit standalone root. A missing
-- ledger means no pins, while any existing malformed or unreadable ledger is an
-- error. contextFile is the canonical root-relative selector.
export
loadPinContext : String -> <IO> Result String PinContext
loadPinContext target =
  let targetPath = canonicalizePath target
  let targetDir = dirOf targetPath
  match findProjectRoot targetDir
    Some root => loadAtRoot (canonicalizePath root) targetPath
    None => loadAtRoot (canonicalizePath targetDir) targetPath

loadAtRoot : String -> String -> <IO> Result String PinContext
loadAtRoot root target = do
  file <- relativeToRoot root target
  let ledger = joinPath root ledgerName
  match ledgerPresent root ledger
    Err err => Err err
    Ok False =>
      Ok PinContext { contextRoot = root, contextFile = file, contextPins = [] }
    Ok True => do
      _ <- relativeToRoot root (canonicalizePath ledger)
      match readFile ledger
        Err err => Err "\{ledger}: cannot read known-red ledger: \{err}"
        Ok src => do
          pins <- parsePins src
          _ <- validatePinFiles root pins
          Ok PinContext {
            contextRoot = root,
            contextFile = file,
            contextPins = filterList (pin => pin.pinFile == file) pins,
          }

-- `fileExists` follows a symlink, so a dangling ledger link reads False. The
-- parent directory still contains its name: distinguish that broken ledger from
-- a genuinely absent optional ledger and fail loudly for the former.
ledgerPresent : String -> String -> <FileRead> Result String Bool
ledgerPresent root ledger =
  if fileExists ledger then
    Ok True
  else match listDir root
    Err err => Err "\{root}: cannot inspect known-red ledger: \{err}"
    Ok names =>
      if contains ledgerName names then
        Err "\{ledger}: cannot read known-red ledger"
      else
        Ok False

-- Paths are only compared after canonicalizePath. The slash in the prefix is
-- load-bearing: /tmp/app2 must never count as being under /tmp/app.
relativeToRoot : String -> String -> Result String String
relativeToRoot root path =
  let prefix = if root == "/" then "/" else root ++ "/"
  if startsWith prefix path then
    let n = if root == "/" then 1 else stringLength root + 1
    let rel = drop n path
    if rel == "" then
      Err "known-red ledger target '\{path}' is not a file below '\{root}'"
    else
      Ok rel
  else
    Err "known-red ledger target '\{path}' escapes selected root '\{root}'"

validatePinFiles : String -> List TestPin -> <FileRead> Result String Unit
validatePinFiles _ [] = Ok ()
validatePinFiles root (pin :: rest) = do
  let raw = joinPath root pin.pinFile
  let resolved = canonicalizePath raw
  canonicalFile <- relativeToRoot root resolved
  if canonicalFile /= pin.pinFile then
    Err
      "medaka-test-pins.toml: referenced file '\{pin.pinFile}' is not its canonical project-relative path ('\{canonicalFile}')"
  else match isFile resolved
    Err _ =>
      Err
        "medaka-test-pins.toml: referenced file '\{pin.pinFile}' does not exist"
    Ok False =>
      Err
        "medaka-test-pins.toml: referenced file '\{pin.pinFile}' is not a regular file"
    Ok True => validatePinFiles root rest
# DESUGAR
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false))))
(DUse false (UseGroup ("fs") ((mem "isFile" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "joinPath" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "filterList" false))))
(DUse false (UseGroup ("tools" "test_pins") ((mem "TestPin" false) (mem "parsePins" false))))
(DUse false (UseGroup ("string") ((mem "drop" false) (mem "startsWith" false))))
(DData Public "PinContext" () ((variant "PinContext" (ConNamed (field "contextRoot" (TyCon "String")) (field "contextFile" (TyCon "String")) (field "contextPins" (TyApp (TyCon "List") (TyCon "TestPin")))))) ())
(DTypeSig false "ledgerName" (TyCon "String"))
(DFunDef false "ledgerName" () (ELit (LString "medaka-test-pins.toml")))
(DTypeSig true "loadPinContext" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PinContext")))))
(DFunDef false "loadPinContext" ((PVar "target")) (EBlock (DoLet false false (PVar "targetPath") (EApp (EVar "canonicalizePath") (EVar "target"))) (DoLet false false (PVar "targetDir") (EApp (EVar "dirOf") (EVar "targetPath"))) (DoExpr (EMatch (EApp (EVar "findProjectRoot") (EVar "targetDir")) (arm (PCon "Some" (PVar "root")) () (EApp (EApp (EVar "loadAtRoot") (EApp (EVar "canonicalizePath") (EVar "root"))) (EVar "targetPath"))) (arm (PCon "None") () (EApp (EApp (EVar "loadAtRoot") (EApp (EVar "canonicalizePath") (EVar "targetDir"))) (EVar "targetPath")))))))
(DTypeSig false "loadAtRoot" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PinContext"))))))
(DFunDef false "loadAtRoot" ((PVar "root") (PVar "target")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "relativeToRoot") (EVar "root")) (EVar "target"))) (ELam ((PVar "file")) (ELet false (PVar "ledger") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "ledgerName")) (EMatch (EApp (EApp (EVar "ledgerPresent") (EVar "root")) (EVar "ledger")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EVar "err"))) (arm (PCon "Ok" (PCon "False")) () (EApp (EVar "Ok") (ERecordCreate "PinContext" ((fa "contextRoot" (EVar "root")) (fa "contextFile" (EVar "file")) (fa "contextPins" (EListLit)))))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "relativeToRoot") (EVar "root")) (EApp (EVar "canonicalizePath") (EVar "ledger")))) (ELam (PWild) (EMatch (EApp (EVar "readFile") (EVar "ledger")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ledger"))) (ELit (LString ": cannot read known-red ledger: "))) (EApp (EVar "display") (EVar "err"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EVar "andThen") (EApp (EVar "parsePins") (EVar "src"))) (ELam ((PVar "pins")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "validatePinFiles") (EVar "root")) (EVar "pins"))) (ELam (PWild) (EApp (EVar "Ok") (ERecordCreate "PinContext" ((fa "contextRoot" (EVar "root")) (fa "contextFile" (EVar "file")) (fa "contextPins" (EApp (EApp (EVar "filterList") (ELam ((PVar "pin")) (EBinOp "==" (EFieldAccess (EVar "pin") "pinFile") (EVar "file")))) (EVar "pins"))))))))))))))))))))
(DTypeSig false "ledgerPresent" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "ledgerPresent" ((PVar "root") (PVar "ledger")) (EIf (EApp (EVar "fileExists") (EVar "ledger")) (EApp (EVar "Ok") (EVar "True")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString ": cannot inspect known-red ledger: "))) (EApp (EVar "display") (EVar "err"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EIf (EApp (EApp (EVar "contains") (EVar "ledgerName")) (EVar "names")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ledger"))) (ELit (LString ": cannot read known-red ledger")))) (EApp (EVar "Ok") (EVar "False")))))))
(DTypeSig false "relativeToRoot" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "relativeToRoot" ((PVar "root") (PVar "path")) (EBlock (DoLet false false (PVar "prefix") (EIf (EBinOp "==" (EVar "root") (ELit (LString "/"))) (ELit (LString "/")) (EBinOp "++" (EVar "root") (ELit (LString "/"))))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "path")) (EBlock (DoLet false false (PVar "n") (EIf (EBinOp "==" (EVar "root") (ELit (LString "/"))) (ELit (LInt 1)) (EBinOp "+" (EApp (EVar "stringLength") (EVar "root")) (ELit (LInt 1))))) (DoLet false false (PVar "rel") (EApp (EApp (EVar "drop") (EVar "n")) (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "rel") (ELit (LString ""))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "known-red ledger target '")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "' is not a file below '"))) (EApp (EVar "display") (EVar "root"))) (ELit (LString "'")))) (EApp (EVar "Ok") (EVar "rel"))))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "known-red ledger target '")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "' escapes selected root '"))) (EApp (EVar "display") (EVar "root"))) (ELit (LString "'"))))))))
(DTypeSig false "validatePinFiles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "validatePinFiles" (PWild (PList)) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validatePinFiles" ((PVar "root") (PCons (PVar "pin") (PVar "rest"))) (ELet false (PVar "raw") (EApp (EApp (EVar "joinPath") (EVar "root")) (EFieldAccess (EVar "pin") "pinFile")) (ELet false (PVar "resolved") (EApp (EVar "canonicalizePath") (EVar "raw")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "relativeToRoot") (EVar "root")) (EVar "resolved"))) (ELam ((PVar "canonicalFile")) (EIf (EBinOp "/=" (EVar "canonicalFile") (EFieldAccess (EVar "pin") "pinFile")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka-test-pins.toml: referenced file '")) (EApp (EVar "display") (EFieldAccess (EVar "pin") "pinFile"))) (ELit (LString "' is not its canonical project-relative path ('"))) (EApp (EVar "display") (EVar "canonicalFile"))) (ELit (LString "')")))) (EMatch (EApp (EVar "isFile") (EVar "resolved")) (arm (PCon "Err" PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka-test-pins.toml: referenced file '")) (EApp (EVar "display") (EFieldAccess (EVar "pin") "pinFile"))) (ELit (LString "' does not exist"))))) (arm (PCon "Ok" (PCon "False")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka-test-pins.toml: referenced file '")) (EApp (EVar "display") (EFieldAccess (EVar "pin") "pinFile"))) (ELit (LString "' is not a regular file"))))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EVar "validatePinFiles") (EVar "root")) (EVar "rest"))))))))))
# MARK
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false))))
(DUse false (UseGroup ("fs") ((mem "isFile" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "joinPath" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "filterList" false))))
(DUse false (UseGroup ("tools" "test_pins") ((mem "TestPin" false) (mem "parsePins" false))))
(DUse false (UseGroup ("string") ((mem "drop" false) (mem "startsWith" false))))
(DData Public "PinContext" () ((variant "PinContext" (ConNamed (field "contextRoot" (TyCon "String")) (field "contextFile" (TyCon "String")) (field "contextPins" (TyApp (TyCon "List") (TyCon "TestPin")))))) ())
(DTypeSig false "ledgerName" (TyCon "String"))
(DFunDef false "ledgerName" () (ELit (LString "medaka-test-pins.toml")))
(DTypeSig true "loadPinContext" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PinContext")))))
(DFunDef false "loadPinContext" ((PVar "target")) (EBlock (DoLet false false (PVar "targetPath") (EApp (EVar "canonicalizePath") (EVar "target"))) (DoLet false false (PVar "targetDir") (EApp (EVar "dirOf") (EVar "targetPath"))) (DoExpr (EMatch (EApp (EVar "findProjectRoot") (EVar "targetDir")) (arm (PCon "Some" (PVar "root")) () (EApp (EApp (EVar "loadAtRoot") (EApp (EVar "canonicalizePath") (EVar "root"))) (EVar "targetPath"))) (arm (PCon "None") () (EApp (EApp (EVar "loadAtRoot") (EApp (EVar "canonicalizePath") (EVar "targetDir"))) (EVar "targetPath")))))))
(DTypeSig false "loadAtRoot" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "PinContext"))))))
(DFunDef false "loadAtRoot" ((PVar "root") (PVar "target")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "relativeToRoot") (EVar "root")) (EVar "target"))) (ELam ((PVar "file")) (ELet false (PVar "ledger") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "ledgerName")) (EMatch (EApp (EApp (EVar "ledgerPresent") (EVar "root")) (EVar "ledger")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EVar "err"))) (arm (PCon "Ok" (PCon "False")) () (EApp (EVar "Ok") (ERecordCreate "PinContext" ((fa "contextRoot" (EVar "root")) (fa "contextFile" (EVar "file")) (fa "contextPins" (EListLit)))))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "relativeToRoot") (EVar "root")) (EApp (EVar "canonicalizePath") (EVar "ledger")))) (ELam (PWild) (EMatch (EApp (EVar "readFile") (EVar "ledger")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ledger"))) (ELit (LString ": cannot read known-red ledger: "))) (EApp (EMethodRef "display") (EVar "err"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "parsePins") (EVar "src"))) (ELam ((PVar "pins")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "validatePinFiles") (EVar "root")) (EVar "pins"))) (ELam (PWild) (EApp (EVar "Ok") (ERecordCreate "PinContext" ((fa "contextRoot" (EVar "root")) (fa "contextFile" (EVar "file")) (fa "contextPins" (EApp (EApp (EVar "filterList") (ELam ((PVar "pin")) (EBinOp "==" (EFieldAccess (EVar "pin") "pinFile") (EVar "file")))) (EVar "pins"))))))))))))))))))))
(DTypeSig false "ledgerPresent" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "ledgerPresent" ((PVar "root") (PVar "ledger")) (EIf (EApp (EVar "fileExists") (EVar "ledger")) (EApp (EVar "Ok") (EVar "True")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "err")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString ": cannot inspect known-red ledger: "))) (EApp (EMethodRef "display") (EVar "err"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "names")) () (EIf (EApp (EApp (EVar "contains") (EVar "ledgerName")) (EVar "names")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ledger"))) (ELit (LString ": cannot read known-red ledger")))) (EApp (EVar "Ok") (EVar "False")))))))
(DTypeSig false "relativeToRoot" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "relativeToRoot" ((PVar "root") (PVar "path")) (EBlock (DoLet false false (PVar "prefix") (EIf (EBinOp "==" (EVar "root") (ELit (LString "/"))) (ELit (LString "/")) (EBinOp "++" (EVar "root") (ELit (LString "/"))))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "path")) (EBlock (DoLet false false (PVar "n") (EIf (EBinOp "==" (EVar "root") (ELit (LString "/"))) (ELit (LInt 1)) (EBinOp "+" (EApp (EVar "stringLength") (EVar "root")) (ELit (LInt 1))))) (DoLet false false (PVar "rel") (EApp (EApp (EVar "drop") (EVar "n")) (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "rel") (ELit (LString ""))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "known-red ledger target '")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "' is not a file below '"))) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "'")))) (EApp (EVar "Ok") (EVar "rel"))))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "known-red ledger target '")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "' escapes selected root '"))) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "'"))))))))
(DTypeSig false "validatePinFiles" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "TestPin")) (TyEffect ("FileRead") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "validatePinFiles" (PWild (PList)) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validatePinFiles" ((PVar "root") (PCons (PVar "pin") (PVar "rest"))) (ELet false (PVar "raw") (EApp (EApp (EVar "joinPath") (EVar "root")) (EFieldAccess (EVar "pin") "pinFile")) (ELet false (PVar "resolved") (EApp (EVar "canonicalizePath") (EVar "raw")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "relativeToRoot") (EVar "root")) (EVar "resolved"))) (ELam ((PVar "canonicalFile")) (EIf (EBinOp "/=" (EVar "canonicalFile") (EFieldAccess (EVar "pin") "pinFile")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka-test-pins.toml: referenced file '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "pin") "pinFile"))) (ELit (LString "' is not its canonical project-relative path ('"))) (EApp (EMethodRef "display") (EVar "canonicalFile"))) (ELit (LString "')")))) (EMatch (EApp (EVar "isFile") (EVar "resolved")) (arm (PCon "Err" PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka-test-pins.toml: referenced file '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "pin") "pinFile"))) (ELit (LString "' does not exist"))))) (arm (PCon "Ok" (PCon "False")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka-test-pins.toml: referenced file '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "pin") "pinFile"))) (ELit (LString "' is not a regular file"))))) (arm (PCon "Ok" (PCon "True")) () (EApp (EApp (EVar "validatePinFiles") (EVar "root")) (EVar "rest"))))))))))
