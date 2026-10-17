# META
source_lines=79
stages=DESUGAR,MARK
# SOURCE
-- The ES-module loader `medaka build --target wasmgc/edge` writes beside the wasm.
-- Its text is small on purpose: running the program and shaping the response live
-- in playground/medaka_host.mjs (`runToResult`, `textResponse`), so the only thing
-- spliced in here is the wasm file name, as a JS string literal.
--
-- Two forms, one per way a runtime hands over a `WebAssembly.Module`: `import
-- source` (workerd, Node 24, Deno; wrangler bundles it) and a read-and-compile of
-- the sibling file (Bun, which cannot parse `import source`; workerd refuses
-- runtime compilation).  Both install exactly the edge slice set, never by user
-- agent, and export `run` and a default `{ fetch }`.

import support.util.{escStr, escOneHex2}
import types.target_profile.{TargetProfile, profileName}

edgeProfileName : String
edgeProfileName = "wasmgc/edge"

-- A JS string literal for the wasm file name, relative to the loader.  The name is
-- percent-encoded first because a module specifier and `new URL` both read it as a
-- URL, where `#`, `?` and `%` would otherwise end or alter the path.  What remains
-- has no quote, backslash or control character, so `escStr`'s JS string syntax
-- (which writes NUL as `\0`, valid only when no digit follows) never meets one.
wasmPathLiteral : String -> String
wasmPathLiteral wasmFile = escStr (urlPathEncode ("./" ++ wasmFile))

urlPathEncode : String -> String
urlPathEncode s = stringConcat (urlPathFrom (stringToChars s) 0)

urlPathFrom : Array Char -> Int -> List String
urlPathFrom arr i
  | i >= arrayLength arr = []
  | otherwise = urlPathChar (arrayGetUnsafe i arr) :: urlPathFrom arr (i + 1)

urlPathChar : Char -> String
urlPathChar c
  | charCode c >= 128 = charToStr c
  | isUrlSafe (charCode c) = charToStr c
  | otherwise = "%" ++ escOneHex2 (charCode c)

-- Letters, digits and the marks `encodeURIComponent` leaves alone, plus `/`.
isUrlSafe : Int -> Bool
isUrlSafe n =
  n >= 48 && n <= 57
    || n >= 65 && n <= 90
    || n >= 97 && n <= 122
    || any (== n) [33, 39, 40, 41, 42, 45, 46, 47, 95, 126]

-- The part of the loader both forms share: the profile and the two exports.
loaderBody : String
loaderBody =
  "import { runToResult, textResponse } from \"./medaka_host.mjs\";\n"
    ++ "const profile = \"\{edgeProfileName}\";\n"
    ++ "export const run = (opts = {}) => runToResult(wasmModule, profile, opts);\n"
    ++ "export default {\n"
    ++ "  async fetch(request) {\n"
    ++ "    const result = await run();\n"
    ++ "    if (result.stderr) console.error(result.stderr);\n"
    ++ "    return textResponse(result);\n"
    ++ "  },\n"
    ++ "};\n"

-- The `import source` loader for `wasmFile` (a file name beside the loader), or
-- `None` for a profile that has no edge loader.
export
edgeLoader : TargetProfile -> String -> Option String
edgeLoader p wasmFile
  | profileName p == edgeProfileName =
    Some
      "import source wasmModule from \{wasmPathLiteral wasmFile};\n\{loaderBody}"
  | otherwise = None

-- The read-and-compile twin, for runtimes that cannot parse `import source`.
export
edgeBytesLoader : TargetProfile -> String -> Option String
edgeBytesLoader p wasmFile
  | profileName p == edgeProfileName =
    Some
      "import { readFile } from \"node:fs/promises\";\nconst wasmModule = await WebAssembly.compile(await readFile(new URL(\{wasmPathLiteral wasmFile}, import.meta.url)));\n\{loaderBody}"
  | otherwise = None
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "escOneHex2" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "profileName" false))))
(DTypeSig false "edgeProfileName" (TyCon "String"))
(DFunDef false "edgeProfileName" () (ELit (LString "wasmgc/edge")))
(DTypeSig false "wasmPathLiteral" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "wasmPathLiteral" ((PVar "wasmFile")) (EApp (EVar "escStr") (EApp (EVar "urlPathEncode") (EBinOp "++" (ELit (LString "./")) (EVar "wasmFile")))))
(DTypeSig false "urlPathEncode" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "urlPathEncode" ((PVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "urlPathFrom") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0)))))
(DTypeSig false "urlPathFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "urlPathFrom" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "urlPathChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EVar "urlPathFrom") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "urlPathChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "urlPathChar" ((PVar "c")) (EIf (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 128))) (EApp (EVar "charToStr") (EVar "c")) (EIf (EApp (EVar "isUrlSafe") (EApp (EVar "charCode") (EVar "c"))) (EApp (EVar "charToStr") (EVar "c")) (EIf (EVar "otherwise") (EBinOp "++" (ELit (LString "%")) (EApp (EVar "escOneHex2") (EApp (EVar "charCode") (EVar "c")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isUrlSafe" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isUrlSafe" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (EBinOp "<=" (EVar "n") (ELit (LInt 57)))) (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 90))))) (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 122))))) (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EListLit (ELit (LInt 33)) (ELit (LInt 39)) (ELit (LInt 40)) (ELit (LInt 41)) (ELit (LInt 42)) (ELit (LInt 45)) (ELit (LInt 46)) (ELit (LInt 47)) (ELit (LInt 95)) (ELit (LInt 126))))))
(DTypeSig false "loaderBody" (TyCon "String"))
(DFunDef false "loaderBody" () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import { runToResult, textResponse } from \"./medaka_host.mjs\";\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "const profile = \"")) (EApp (EVar "display") (EVar "edgeProfileName"))) (ELit (LString "\";\n")))) (ELit (LString "export const run = (opts = {}) => runToResult(wasmModule, profile, opts);\n"))) (ELit (LString "export default {\n"))) (ELit (LString "  async fetch(request) {\n"))) (ELit (LString "    const result = await run();\n"))) (ELit (LString "    if (result.stderr) console.error(result.stderr);\n"))) (ELit (LString "    return textResponse(result);\n"))) (ELit (LString "  },\n"))) (ELit (LString "};\n"))))
(DTypeSig true "edgeLoader" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "edgeLoader" ((PVar "p") (PVar "wasmFile")) (EIf (EBinOp "==" (EApp (EVar "profileName") (EVar "p")) (EVar "edgeProfileName")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import source wasmModule from ")) (EApp (EVar "display") (EApp (EVar "wasmPathLiteral") (EVar "wasmFile")))) (ELit (LString ";\n"))) (EApp (EVar "display") (EVar "loaderBody"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "edgeBytesLoader" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "edgeBytesLoader" ((PVar "p") (PVar "wasmFile")) (EIf (EBinOp "==" (EApp (EVar "profileName") (EVar "p")) (EVar "edgeProfileName")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import { readFile } from \"node:fs/promises\";\nconst wasmModule = await WebAssembly.compile(await readFile(new URL(")) (EApp (EVar "display") (EApp (EVar "wasmPathLiteral") (EVar "wasmFile")))) (ELit (LString ", import.meta.url)));\n"))) (EApp (EVar "display") (EVar "loaderBody"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "escOneHex2" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "profileName" false))))
(DTypeSig false "edgeProfileName" (TyCon "String"))
(DFunDef false "edgeProfileName" () (ELit (LString "wasmgc/edge")))
(DTypeSig false "wasmPathLiteral" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "wasmPathLiteral" ((PVar "wasmFile")) (EApp (EVar "escStr") (EApp (EVar "urlPathEncode") (EBinOp "++" (ELit (LString "./")) (EVar "wasmFile")))))
(DTypeSig false "urlPathEncode" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "urlPathEncode" ((PVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "urlPathFrom") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0)))))
(DTypeSig false "urlPathFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "urlPathFrom" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "urlPathChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EVar "urlPathFrom") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "urlPathChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "urlPathChar" ((PVar "c")) (EIf (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 128))) (EApp (EVar "charToStr") (EVar "c")) (EIf (EApp (EVar "isUrlSafe") (EApp (EVar "charCode") (EVar "c"))) (EApp (EVar "charToStr") (EVar "c")) (EIf (EVar "otherwise") (EBinOp "++" (ELit (LString "%")) (EApp (EVar "escOneHex2") (EApp (EVar "charCode") (EVar "c")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isUrlSafe" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isUrlSafe" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (EBinOp "<=" (EVar "n") (ELit (LInt 57)))) (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 90))))) (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 122))))) (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EListLit (ELit (LInt 33)) (ELit (LInt 39)) (ELit (LInt 40)) (ELit (LInt 41)) (ELit (LInt 42)) (ELit (LInt 45)) (ELit (LInt 46)) (ELit (LInt 47)) (ELit (LInt 95)) (ELit (LInt 126))))))
(DTypeSig false "loaderBody" (TyCon "String"))
(DFunDef false "loaderBody" () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import { runToResult, textResponse } from \"./medaka_host.mjs\";\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "const profile = \"")) (EApp (EMethodRef "display") (EVar "edgeProfileName"))) (ELit (LString "\";\n")))) (ELit (LString "export const run = (opts = {}) => runToResult(wasmModule, profile, opts);\n"))) (ELit (LString "export default {\n"))) (ELit (LString "  async fetch(request) {\n"))) (ELit (LString "    const result = await run();\n"))) (ELit (LString "    if (result.stderr) console.error(result.stderr);\n"))) (ELit (LString "    return textResponse(result);\n"))) (ELit (LString "  },\n"))) (ELit (LString "};\n"))))
(DTypeSig true "edgeLoader" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "edgeLoader" ((PVar "p") (PVar "wasmFile")) (EIf (EBinOp "==" (EApp (EVar "profileName") (EVar "p")) (EVar "edgeProfileName")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import source wasmModule from ")) (EApp (EMethodRef "display") (EApp (EVar "wasmPathLiteral") (EVar "wasmFile")))) (ELit (LString ";\n"))) (EApp (EMethodRef "display") (EVar "loaderBody"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "edgeBytesLoader" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "edgeBytesLoader" ((PVar "p") (PVar "wasmFile")) (EIf (EBinOp "==" (EApp (EVar "profileName") (EVar "p")) (EVar "edgeProfileName")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import { readFile } from \"node:fs/promises\";\nconst wasmModule = await WebAssembly.compile(await readFile(new URL(")) (EApp (EMethodRef "display") (EApp (EVar "wasmPathLiteral") (EVar "wasmFile")))) (ELit (LString ", import.meta.url)));\n"))) (EApp (EMethodRef "display") (EVar "loaderBody"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
