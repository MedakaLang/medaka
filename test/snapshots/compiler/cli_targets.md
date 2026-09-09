# META
source_lines=83
stages=DESUGAR,MARK
# SOURCE
-- compiler/support/cli_targets.mdk — the shared CLI TARGET walk.
--
-- Turning a user-supplied path into the concrete list of `.mdk` files a verb
-- operates on is one behavior, not five: `lint`, `fmt`, `codemod`, `test` and
-- `snapshot` all expand a directory argument through this walk, so a change to
-- what counts as a target (the listDir dir/file discriminator, the dot-entry
-- skip, the sort) reaches every one of them at once.  It lives under
-- `support/` rather than beside any one verb because it has those five
-- consumers and no owning stage.
--
-- No argv lives here.  Flag vocabulary, rejection and help text stay with each
-- verb.  That is a convention, not something a gate enforces from this side:
-- `test/diff_compiler_cli_reject_floor.sh`'s unrouted-arm scan reads all of
-- `compiler/` except `entries/`, so it would see a flag literal here too.
--
-- The diagnostics still say "medaka lint:" because that is the wording every
-- caller shipped before the walk was shared; changing it would change bytes.

import support.util.{endsWith, sortUniqS, startsWith}

-- #1173: a lint target that is neither a listable directory nor a readable
-- file used to fall through `expandLintTarget`'s `Err _ => [target]` arm as a
-- literal path, which `lintFileDiagTriple` then reads via `readFileSafe` — the
-- same "" -on-error helper `checkJsonFile` uses — so a nonexistent path parsed
-- as EMPTY SOURCE and reported a clean 0-diagnostic result at exit 0. Fail
-- loudly up front instead (mirrors `assertSnapshotTargetsExist` in
-- `compiler/driver/medaka_cli.mdk`).
export
lintTargetExists : String -> <IO> Bool
lintTargetExists t = match listDir t
  Ok _ => True
  Err _ => fileExists t

-- One target: a listable path is a directory (recursively collect its .mdk
-- files); otherwise a literal file path, kept as-is.
export
expandLintTarget : String -> <IO> List String
expandLintTarget target = match listDir target
  Ok _ => collectMdkFiles target
  Err _ => [target]

-- Join a directory path with an entry name (handles trailing slash).
lintPathJoin : String -> String -> String
lintPathJoin dir name =
  if endsWith "/" dir then dir ++ name else "\{dir}/\{name}"

-- Recursively collect every `.mdk` file under `dir`, sorted (deterministic).
-- Walks SUBDIRECTORIES; skips dot-entries (dotfiles AND dot-directories like
-- `.git`/`.claude`).  A failed top-level `listDir` reports once and yields [].
export
collectMdkFiles : String -> <IO> List String
collectMdkFiles dir = match listDir dir
  Err msg =>
    let _ = ePutStrLn "medaka lint: cannot list directory \{dir}: \{msg}"
    []
  Ok _ => sortUniqS (collectMdkFilesRec dir)

collectMdkFilesRec : String -> <IO> List String
collectMdkFilesRec dir = match listDir dir
  Err _ => []
  Ok entries => collectMdkEntries dir (filterNonDot entries)

collectMdkEntries : String -> List String -> <IO> List String
collectMdkEntries _ [] = []
collectMdkEntries dir (name :: rest) =
  collectMdkEntry dir name ++ collectMdkEntries dir rest

-- One entry: a listable path is a subdirectory (recurse); otherwise a file,
-- kept iff it ends in `.mdk`.  Mirrors the dir/file discriminator used elsewhere
-- (listDir Ok = dir, Err = file).
collectMdkEntry : String -> String -> <IO> List String
collectMdkEntry dir name =
  let full = lintPathJoin dir name
  match listDir full
    Ok _ => collectMdkFilesRec full
    Err _ => if endsWith ".mdk" name then [full] else []

-- Drop dot-entries (dotfiles and dot-directories) from a listDir result.
filterNonDot : List String -> List String
filterNonDot [] = []
filterNonDot (n :: rest)
  | startsWith "." n = filterNonDot rest
  | otherwise = n :: filterNonDot rest
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "endsWith" false) (mem "sortUniqS" false) (mem "startsWith" false))))
(DTypeSig true "lintTargetExists" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "lintTargetExists" ((PVar "t")) (EMatch (EApp (EVar "listDir") (EVar "t")) (arm (PCon "Ok" PWild) () (EVar "True")) (arm (PCon "Err" PWild) () (EApp (EVar "fileExists") (EVar "t")))))
(DTypeSig true "expandLintTarget" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expandLintTarget" ((PVar "target")) (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFiles") (EVar "target"))) (arm (PCon "Err" PWild) () (EListLit (EVar "target")))))
(DTypeSig false "lintPathJoin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "lintPathJoin" ((PVar "dir") (PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "dir")) (EBinOp "++" (EVar "dir") (EVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig true "collectMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFiles" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: cannot list directory ")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EListLit)))) (arm (PCon "Ok" PWild) () (EApp (EVar "sortUniqS") (EApp (EVar "collectMdkFilesRec") (EVar "dir"))))))
(DTypeSig false "collectMdkFilesRec" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFilesRec" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EApp (EVar "filterNonDot") (EVar "entries"))))))
(DTypeSig false "collectMdkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntries" (PWild (PList)) (EListLit))
(DFunDef false "collectMdkEntries" ((PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "collectMdkEntry") (EVar "dir")) (EVar "name")) (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EVar "rest"))))
(DTypeSig false "collectMdkEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntry" ((PVar "dir") (PVar "name")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "lintPathJoin") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFilesRec") (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EListLit (EVar "full")) (EListLit)))))))
(DTypeSig false "filterNonDot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonDot" ((PList)) (EListLit))
(DFunDef false "filterNonDot" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EApp (EVar "filterNonDot") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EVar "filterNonDot") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "endsWith" false) (mem "sortUniqS" false) (mem "startsWith" false))))
(DTypeSig true "lintTargetExists" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "lintTargetExists" ((PVar "t")) (EMatch (EApp (EVar "listDir") (EVar "t")) (arm (PCon "Ok" PWild) () (EVar "True")) (arm (PCon "Err" PWild) () (EApp (EVar "fileExists") (EVar "t")))))
(DTypeSig true "expandLintTarget" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expandLintTarget" ((PVar "target")) (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFiles") (EVar "target"))) (arm (PCon "Err" PWild) () (EListLit (EVar "target")))))
(DTypeSig false "lintPathJoin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "lintPathJoin" ((PVar "dir") (PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "dir")) (EBinOp "++" (EVar "dir") (EVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig true "collectMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFiles" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: cannot list directory ")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EListLit)))) (arm (PCon "Ok" PWild) () (EApp (EVar "sortUniqS") (EApp (EVar "collectMdkFilesRec") (EVar "dir"))))))
(DTypeSig false "collectMdkFilesRec" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFilesRec" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EApp (EVar "filterNonDot") (EVar "entries"))))))
(DTypeSig false "collectMdkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntries" (PWild (PList)) (EListLit))
(DFunDef false "collectMdkEntries" ((PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "collectMdkEntry") (EVar "dir")) (EVar "name")) (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EVar "rest"))))
(DTypeSig false "collectMdkEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntry" ((PVar "dir") (PVar "name")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "lintPathJoin") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFilesRec") (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EListLit (EVar "full")) (EListLit)))))))
(DTypeSig false "filterNonDot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonDot" ((PList)) (EListLit))
(DFunDef false "filterNonDot" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EApp (EVar "filterNonDot") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EVar "filterNonDot") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
