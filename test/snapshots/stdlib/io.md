# META
source_lines=76
stages=DESUGAR,MARK
# SOURCE
{- | Output to standard error, debug printing, and helpers for files and
   the environment.

   The primitive operations are in scope without an import: `readFile`,
   `writeFile`, `appendFile`, `readLine`, `readLineOpt`, `readAll`, `args`,
   `getEnv`, `fileExists`, `listDir`, `exit`, `putStr`, `putStrLn`,
   `ePutStr`, and `ePutStrLn`, plus `print` and `println` from the prelude.
   This module adds the convenience layer on top of them.

   File operations return `Result String a`, with the host's error message
   in `Err`. There is no IO monad: an action runs when it is evaluated, so
   `match readFile path` works directly. -}

import core.{Debug, Display, Option, Result, optionOr}
import string.{stripCR}

-- # Standard error

{- | Writes a value to standard error with no trailing newline.

   The value is rendered with `display`, like `print`. -}
export
eprint : Display a => a -> <IO> Unit
eprint x = ePutStr (display x)

{- | Writes a value to standard error, followed by a newline.

   The value is rendered with `display`, like `println`. Use it for
   diagnostics and errors so they do not mix with standard output. -}
export
eprintln : Display a => a -> <IO> Unit
eprintln x = ePutStrLn (display x)

-- # Debug output

{- | Writes a value to standard output in its `debug` rendering, followed by
   a newline.

   Unlike `println`, strings and characters are quoted and constructors are
   shown by name, so the output reads as Medaka source. Use it to trace
   values without writing a `Display` instance. -}
export
inspect : Debug a => a -> <IO> Unit
inspect x = putStrLn (debug x)

-- # Files

-- Line splitting is done here over the global `string*` kernel externs (in
-- runtime.mdk) rather than `import string.{lines}`, because `string.lines`
-- deliberately keeps the final empty line a trailing newline produces,
-- whereas readLines drops it.  Splits on `\n`, dropping a trailing `\r` (so
-- CRLF files work) and the final empty line a trailing newline would
-- otherwise produce.  `stripCR` is `string.stripCR`, imported.
splitLines : String -> List String
splitLines s = match stringIndexOf "\n" s
  None => if s == "" then [] else [stripCR s]
  Some i =>
    stripCR (stringSlice 0 i s)
      :: splitLines (stringSlice (i + 1) (stringLength s) s)

{- | The lines of a file, or `Err` with the host's message when the file
   cannot be read.

   Lines are split on `\n`, with a `\r` before it removed. A trailing
   newline does not produce a final empty line. -}
export
readLines : String -> <IO> Result String (List String)
readLines path = map splitLines (readFile path)

-- # Environment

-- | The value of the environment variable `name`, or `fallback` when it is
-- unset.
export
getEnvOr : String -> String -> <IO> String
getEnvOr name fallback = optionOr fallback (getEnv name)
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Debug" false) (mem "Display" false) (mem "Option" false) (mem "Result" false) (mem "optionOr" false))))
(DUse false (UseGroup ("string") ((mem "stripCR" false))))
(DTypeSig true "eprint" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "eprint" ((PVar "x")) (EApp (EVar "ePutStr") (EApp (EVar "display") (EVar "x"))))
(DTypeSig true "eprintln" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "eprintln" ((PVar "x")) (EApp (EVar "ePutStrLn") (EApp (EVar "display") (EVar "x"))))
(DTypeSig true "inspect" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "inspect" ((PVar "x")) (EApp (EVar "putStrLn") (EApp (EVar "debug") (EVar "x"))))
(DTypeSig false "splitLines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLines" ((PVar "s")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "\n"))) (EVar "s")) (arm (PCon "None") () (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EListLit) (EListLit (EApp (EVar "stripCR") (EVar "s"))))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EVar "stripCR") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s"))) (EApp (EVar "splitLines") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))))
(DTypeSig true "readLines" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "readLines" ((PVar "path")) (EApp (EApp (EVar "map") (EVar "splitLines")) (EApp (EVar "readFile") (EVar "path"))))
(DTypeSig true "getEnvOr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "getEnvOr" ((PVar "name") (PVar "fallback")) (EApp (EApp (EVar "optionOr") (EVar "fallback")) (EApp (EVar "getEnv") (EVar "name"))))
# MARK
(DUse false (UseGroup ("core") ((mem "Debug" false) (mem "Display" false) (mem "Option" false) (mem "Result" false) (mem "optionOr" false))))
(DUse false (UseGroup ("string") ((mem "stripCR" false))))
(DTypeSig true "eprint" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "eprint" ((PVar "x")) (EApp (EVar "ePutStr") (EApp (EMethodRef "display") (EVar "x"))))
(DTypeSig true "eprintln" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "eprintln" ((PVar "x")) (EApp (EVar "ePutStrLn") (EApp (EMethodRef "display") (EVar "x"))))
(DTypeSig true "inspect" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "inspect" ((PVar "x")) (EApp (EVar "putStrLn") (EApp (EMethodRef "debug") (EVar "x"))))
(DTypeSig false "splitLines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLines" ((PVar "s")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "\n"))) (EVar "s")) (arm (PCon "None") () (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EListLit) (EListLit (EApp (EVar "stripCR") (EVar "s"))))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EVar "stripCR") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s"))) (EApp (EVar "splitLines") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))))
(DTypeSig true "readLines" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "readLines" ((PVar "path")) (EApp (EApp (EMethodRef "map") (EVar "splitLines")) (EApp (EVar "readFile") (EVar "path"))))
(DTypeSig true "getEnvOr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "getEnvOr" ((PVar "name") (PVar "fallback")) (EApp (EApp (EVar "optionOr") (EVar "fallback")) (EApp (EVar "getEnv") (EVar "name"))))
