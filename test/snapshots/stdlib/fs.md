# META
source_lines=136
stages=DESUGAR,MARK
# SOURCE
{- fs.mdk — a filesystem convenience layer over the host file externs.

   The irreducible host primitives are `extern`s in stdlib/runtime.mdk, so they
   are **global** (no import needed): `readFile`/`writeFile`/`appendFile`,
   `readFileBytes`/`writeFileBytes`, `fileExists`, `listDir`, `makeDir`,
   `removeFile`/`rename`/`removeDir`, `statFile`, `canonicalizePath`. This
   module (`import fs`) adds the ergonomic layer on top — a `FileStat` record
   wrapping `statFile`'s raw tuple, plus composed helpers (`copyFile`,
   `mkdirAll`, `walkDir`, `isDir`/`isFile`/`fileSize`).

   Conventions (mirroring stdlib/io.mdk): file ops return `Result String _`
   with the host error message (errno strerror) in `Err`. There is no IO monad —
   an action runs when it is evaluated, so you can `match copyFile src dst`
   directly.

   Scope: NATIVE/LLVM. Like every file extern, these execute only through the
   compiled (`medaka build`) path, not the tree-walking interpreter. -}

import core.{Result, Ok, Err}
import path.{dirname, joinPath}
import string.{contains}

-- ── FileStat: a named view of statFile's (Int, Bool, Bool, Float) tuple ──────

{- | The metadata `statFile` (stat(2)) returns for a path:
     `size` in bytes, `isDir`/`isFile` type flags, and `mtime` (modification
     time, seconds since the Unix epoch). -}
public export data FileStat =
  | FileStat { size : Int, isDir : Bool, isFile : Bool, mtime : Float }
deriving (Eq, Debug)

{- | `stat path` — like `statFile`, but wraps the raw tuple in a `FileStat`.
     `Err` (strerror) if the path cannot be stat'd (e.g. does not exist). -}
export
stat : String -> <FileRead "_"> Result String FileStat
stat p = map
  ((sz, d, f, m) => FileStat { size = sz, isDir = d, isFile = f, mtime = m })
  (statFile p)

-- ── Composed helpers ─────────────────────────────────────────────────────────

{- | `copyFile src dst` — byte-clean copy: read `src`'s raw bytes, write them to
     `dst` (truncating). Threads the `Result`, so a read failure short-circuits
     before any write. -}
export
copyFile : String -> String -> <FileRead "_", FileWrite "_"> Result String Unit
copyFile src dst = match readFileBytes src
  Ok bytes => writeFileBytes dst bytes
  Err e => Err e

{- | `mkdirAll path` — create `path` and every missing parent directory (like
     `mkdir -p`). Recurses on `path.dirname`, so parents are created first. An
     already-existing directory (an `EEXIST`/"File exists" error from `makeDir`)
     is ignored; any other failure (e.g. permission denied) is reported. Stays
     `<FileWrite _>` — it never reads the filesystem, only writes. -}
export
mkdirAll : String -> <FileWrite "_"> Result String Unit
mkdirAll path =
  if path == "" || path == "." || path == "/" then Ok ()
  else match mkdirAll (dirname path)
    Err e => Err e
    Ok _ => match makeDir path
      Ok _ => Ok ()
      -- EEXIST (strerror "File exists") is success; other errors propagate.
      Err e2 => if contains "exists" e2 then Ok () else Err e2

{- | `walkDir root` — recursively list everything under `root`. Returns FULL
     paths (each prefixed with `root` via `path.joinPath`), depth-first, and
     includes BOTH files and subdirectories. `Err` (strerror) on the first
     directory that cannot be read or entry that cannot be stat'd. -}
export
walkDir : String -> <FileRead "_"> Result String (List String)
walkDir root = match listDir root
  Err e => Err e
  Ok entries => walkEntries root entries []

walkEntries : String -> List String -> List String -> <FileRead "_"> Result String (List String)
walkEntries _ [] acc = Ok acc
walkEntries root (name::rest) acc =
  let full = joinPath root name
  match stat full
    Err e => Err e
    Ok st => if st.isDir then match walkDir full
      Err e => Err e
      Ok sub => walkEntries root rest (acc ++ (full::sub))
    else walkEntries root rest (acc ++ [full])

{- | `isDir path` — `Ok True` if `path` exists and is a directory. -}
export
isDir : String -> <FileRead "_"> Result String Bool
isDir p = map (st => st.isDir) (stat p)

{- | `isFile path` — `Ok True` if `path` exists and is a regular file. -}
export
isFile : String -> <FileRead "_"> Result String Bool
isFile p = map (st => st.isFile) (stat p)

{- | `fileSize path` — the size of `path` in bytes. -}
export
fileSize : String -> <FileRead "_"> Result String Int
fileSize p = map (st => st.size) (stat p)

-- ── Instance laws ────────────────────────────────────────────────────────────
-- `FileStat` is a plain record of four immutable fields, so derived `Eq` is
-- field-wise structural equality.  The externs above do not run under the
-- interpreter, so the laws are stated over hand-built records rather than over
-- a real `stat` call.

-- LAW (A-1): derived `Eq FileStat` is reflexive and discriminates on EVERY
-- field — a derived instance that silently ignored a field would still be
-- reflexive, so both halves are needed.
prop "Eq FileStat is reflexive and field-discriminating" (n : Int) (b : Bool) =
  let base = FileStat {
    size = n,
    isDir = b,
    isFile = not b,
    mtime = intToFloat n,
  }
  base == base
    && base == FileStat { base | size = n + 1 } == False
    && base == FileStat { base | isDir = not b } == False
    && base == FileStat { base | isFile = b } == False
    && base == FileStat { base | mtime = intToFloat n + 1.0 } == False

-- LAW (A-1): derived `Debug FileStat` renders every field, so two records that
-- differ anywhere render differently (and equal records render identically).
prop "Debug FileStat separates records that Eq separates" (n : Int) (b : Bool) =
  let x = FileStat { size = n, isDir = b, isFile = not b, mtime = intToFloat n }
  let y = FileStat { x | size = n + 1 }
  debug x == debug FileStat {
      size = n,
      isDir = b,
      isFile = not b,
      mtime = intToFloat n,
    }
    && debug x == debug y == False
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Result" false) (mem "Ok" false) (mem "Err" false))))
(DUse false (UseGroup ("path") ((mem "dirname" false) (mem "joinPath" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DData Public "FileStat" () ((variant "FileStat" (ConNamed (field "size" (TyCon "Int")) (field "isDir" (TyCon "Bool")) (field "isFile" (TyCon "Bool")) (field "mtime" (TyCon "Float"))))) ())
(DImpl true "Eq" ((TyCon "FileStat")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "FileStat" ((rf "size" (PVar "__a0")) (rf "isDir" (PVar "__a1")) (rf "isFile" (PVar "__a2")) (rf "mtime" (PVar "__a3"))) false) (PRec "FileStat" ((rf "size" (PVar "__b0")) (rf "isDir" (PVar "__b1")) (rf "isFile" (PVar "__b2")) (rf "mtime" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "FileStat")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "FileStat" ((rf "size" (PVar "__a0")) (rf "isDir" (PVar "__a1")) (rf "isFile" (PVar "__a2")) (rf "mtime" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FileStat {")) (ELit (LString " size = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", isDir = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", isFile = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", mtime = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DTypeSig true "stat" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "FileStat")))))
(DFunDef false "stat" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "sz") (PVar "d") (PVar "f") (PVar "m"))) (ERecordCreate "FileStat" ((fa "size" (EVar "sz")) (fa "isDir" (EVar "d")) (fa "isFile" (EVar "f")) (fa "mtime" (EVar "m")))))) (EApp (EVar "statFile") (EVar "p"))))
(DTypeSig true "copyFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileRead") (hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "copyFile" ((PVar "src") (PVar "dst")) (EMatch (EApp (EVar "readFileBytes") (EVar "src")) (arm (PCon "Ok" (PVar "bytes")) () (EApp (EApp (EVar "writeFileBytes") (EVar "dst")) (EVar "bytes"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "mkdirAll" (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "mkdirAll" ((PVar "path")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "path") (ELit (LString ""))) (EBinOp "==" (EVar "path") (ELit (LString ".")))) (EBinOp "==" (EVar "path") (ELit (LString "/")))) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EVar "mkdirAll") (EApp (EVar "dirname") (EVar "path"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "makeDir") (EVar "path")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e2")) () (EIf (EApp (EApp (EVar "contains") (ELit (LString "exists"))) (EVar "e2")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EVar "e2")))))))))
(DTypeSig true "walkDir" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "walkDir" ((PVar "root")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "entries")) (EListLit)))))
(DTypeSig false "walkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "walkEntries" (PWild (PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "walkEntries" ((PVar "root") (PCons (PVar "name") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "stat") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "st")) () (EIf (EFieldAccess (EVar "st") "isDir") (EMatch (EApp (EVar "walkDir") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "sub")) () (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest")) (EBinOp "++" (EVar "acc") (EBinOp "::" (EVar "full") (EVar "sub")))))) (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest")) (EBinOp "++" (EVar "acc") (EListLit (EVar "full"))))))))))
(DTypeSig true "isDir" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isDir" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isDir"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "isFile" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isFile" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isFile"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "fileSize" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "fileSize" ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "size"))) (EApp (EVar "stat") (EVar "p"))))
(DProp false "Eq FileStat is reflexive and field-discriminating" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "base") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n")))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "base") (EVar "base")) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "size" (EBinOp "+" (EVar "n") (ELit (LInt 1))))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "isDir" (EApp (EVar "not") (EVar "b")))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "isFile" (EVar "b"))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "mtime" (EBinOp "+" (EApp (EVar "intToFloat") (EVar "n")) (ELit (LFloat 1.0))))))) (EVar "False"))))))
(DProp false "Debug FileStat separates records that Eq separates" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "x") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n")))))) (DoLet false false (PVar "y") (EVariantUpdate "FileStat" (EVar "x") ((fa "size" (EBinOp "+" (EVar "n") (ELit (LInt 1))))))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "debug") (EVar "x")) (EApp (EVar "debug") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n"))))))) (EBinOp "==" (EBinOp "==" (EApp (EVar "debug") (EVar "x")) (EApp (EVar "debug") (EVar "y"))) (EVar "False"))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Result" false) (mem "Ok" false) (mem "Err" false))))
(DUse false (UseGroup ("path") ((mem "dirname" false) (mem "joinPath" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DData Public "FileStat" () ((variant "FileStat" (ConNamed (field "size" (TyCon "Int")) (field "isDir" (TyCon "Bool")) (field "isFile" (TyCon "Bool")) (field "mtime" (TyCon "Float"))))) ())
(DImpl true "Eq" ((TyCon "FileStat")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "FileStat" ((rf "size" (PVar "__a0")) (rf "isDir" (PVar "__a1")) (rf "isFile" (PVar "__a2")) (rf "mtime" (PVar "__a3"))) false) (PRec "FileStat" ((rf "size" (PVar "__b0")) (rf "isDir" (PVar "__b1")) (rf "isFile" (PVar "__b2")) (rf "mtime" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "FileStat")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "FileStat" ((rf "size" (PVar "__a0")) (rf "isDir" (PVar "__a1")) (rf "isFile" (PVar "__a2")) (rf "mtime" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FileStat {")) (ELit (LString " size = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", isDir = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", isFile = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", mtime = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DTypeSig true "stat" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "FileStat")))))
(DFunDef false "stat" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "sz") (PVar "d") (PVar "f") (PVar "m"))) (ERecordCreate "FileStat" ((fa "size" (EVar "sz")) (fa "isDir" (EVar "d")) (fa "isFile" (EVar "f")) (fa "mtime" (EVar "m")))))) (EApp (EVar "statFile") (EVar "p"))))
(DTypeSig true "copyFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ((hole "FileRead") (hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "copyFile" ((PVar "src") (PVar "dst")) (EMatch (EApp (EVar "readFileBytes") (EVar "src")) (arm (PCon "Ok" (PVar "bytes")) () (EApp (EApp (EVar "writeFileBytes") (EVar "dst")) (EVar "bytes"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "mkdirAll" (TyFun (TyCon "String") (TyEffect ((hole "FileWrite")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "mkdirAll" ((PVar "path")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "path") (ELit (LString ""))) (EBinOp "==" (EVar "path") (ELit (LString ".")))) (EBinOp "==" (EVar "path") (ELit (LString "/")))) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EVar "mkdirAll") (EApp (EVar "dirname") (EVar "path"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EVar "makeDir") (EVar "path")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e2")) () (EIf (EApp (EApp (EVar "contains") (ELit (LString "exists"))) (EVar "e2")) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EVar "e2")))))))))
(DTypeSig true "walkDir" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "walkDir" ((PVar "root")) (EMatch (EApp (EVar "listDir") (EVar "root")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "entries")) (EListLit)))))
(DTypeSig false "walkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "walkEntries" (PWild (PList) (PVar "acc")) (EApp (EVar "Ok") (EVar "acc")))
(DFunDef false "walkEntries" ((PVar "root") (PCons (PVar "name") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "root")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "stat") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "st")) () (EIf (EFieldAccess (EVar "st") "isDir") (EMatch (EApp (EVar "walkDir") (EVar "full")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "sub")) () (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest")) (EBinOp "++" (EVar "acc") (EBinOp "::" (EVar "full") (EMethodRef "sub")))))) (EApp (EApp (EApp (EVar "walkEntries") (EVar "root")) (EVar "rest")) (EBinOp "++" (EVar "acc") (EListLit (EVar "full"))))))))))
(DTypeSig true "isDir" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isDir" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isDir"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "isFile" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isFile" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "isFile"))) (EApp (EVar "stat") (EVar "p"))))
(DTypeSig true "fileSize" (TyFun (TyCon "String") (TyEffect ((hole "FileRead")) None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "fileSize" ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "st")) (EFieldAccess (EVar "st") "size"))) (EApp (EVar "stat") (EVar "p"))))
(DProp false "Eq FileStat is reflexive and field-discriminating" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "base") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n")))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "base") (EVar "base")) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "size" (EBinOp "+" (EVar "n") (ELit (LInt 1))))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "isDir" (EApp (EVar "not") (EVar "b")))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "isFile" (EVar "b"))))) (EVar "False"))) (EBinOp "==" (EBinOp "==" (EVar "base") (EVariantUpdate "FileStat" (EVar "base") ((fa "mtime" (EBinOp "+" (EApp (EVar "intToFloat") (EVar "n")) (ELit (LFloat 1.0))))))) (EVar "False"))))))
(DProp false "Debug FileStat separates records that Eq separates" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "x") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n")))))) (DoLet false false (PVar "y") (EVariantUpdate "FileStat" (EVar "x") ((fa "size" (EBinOp "+" (EVar "n") (ELit (LInt 1))))))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EMethodRef "debug") (EVar "x")) (EApp (EMethodRef "debug") (ERecordCreate "FileStat" ((fa "size" (EVar "n")) (fa "isDir" (EVar "b")) (fa "isFile" (EApp (EVar "not") (EVar "b"))) (fa "mtime" (EApp (EVar "intToFloat") (EVar "n"))))))) (EBinOp "==" (EBinOp "==" (EApp (EMethodRef "debug") (EVar "x")) (EApp (EMethodRef "debug") (EVar "y"))) (EVar "False"))))))
