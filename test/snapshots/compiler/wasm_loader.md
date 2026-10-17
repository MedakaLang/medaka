# META
source_lines=68
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

import types.target_profile.{TargetProfile, profileName}

edgeProfileName : String
edgeProfileName = "wasmgc/edge"

-- A JS string literal for the wasm file name, relative to the loader.
wasmPathLiteral : String -> String
wasmPathLiteral wasmFile =
  let arr = stringToChars ("./" ++ wasmFile)
  stringConcat (["\""] ++ escapeFrom arr 0 ++ ["\""])

escapeFrom : Array Char -> Int -> List String
escapeFrom arr i
  | i >= arrayLength arr = []
  | otherwise = escapeChar (arrayGetUnsafe i arr) :: escapeFrom arr (i + 1)

escapeChar : Char -> String
escapeChar c
  | charCode c == 34 = "\\\""
  | charCode c == 92 = "\\\\"
  | charCode c == 10 = "\\n"
  | charCode c == 13 = "\\r"
  | charCode c < 32 = stringConcat [
    "\\u00",
    stringSlice (charCode c / 16) (charCode c / 16 + 1) "0123456789abcdef",
    stringSlice (charCode c % 16) (charCode c % 16 + 1) "0123456789abcdef",
  ]
  | otherwise = charToStr c

-- The part of the loader both forms share: the profile and the two exports.
loaderBody : String
loaderBody =
  "import { runToResult, textResponse } from \"./medaka_host.mjs\";\n"
    ++ "const profile = \"\{edgeProfileName}\";\n"
    ++ "export const run = (opts = {}) => runToResult(wasmModule, profile, opts);\n"
    ++ "export default {\n"
    ++ "  async fetch(request) { return textResponse(await run()); },\n"
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
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "profileName" false))))
(DTypeSig false "edgeProfileName" (TyCon "String"))
(DFunDef false "edgeProfileName" () (ELit (LString "wasmgc/edge")))
(DTypeSig false "wasmPathLiteral" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "wasmPathLiteral" ((PVar "wasmFile")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EBinOp "++" (ELit (LString "./")) (EVar "wasmFile")))) (DoExpr (EApp (EVar "stringConcat") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "\""))) (EApp (EApp (EVar "escapeFrom") (EVar "arr")) (ELit (LInt 0)))) (EListLit (ELit (LString "\""))))))))
(DTypeSig false "escapeFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escapeFrom" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escapeChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EVar "escapeFrom") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "escapeChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escapeChar" ((PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (ELit (LString "\\\"")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 92))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 10))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 13))) (ELit (LString "\\r")) (EIf (EBinOp "<" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "\\u00")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "/" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 16)))) (EBinOp "+" (EBinOp "/" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 16))) (ELit (LInt 1)))) (ELit (LString "0123456789abcdef"))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "%" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 16)))) (EBinOp "+" (EBinOp "%" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 16))) (ELit (LInt 1)))) (ELit (LString "0123456789abcdef"))))) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "loaderBody" (TyCon "String"))
(DFunDef false "loaderBody" () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import { runToResult, textResponse } from \"./medaka_host.mjs\";\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "const profile = \"")) (EApp (EVar "display") (EVar "edgeProfileName"))) (ELit (LString "\";\n")))) (ELit (LString "export const run = (opts = {}) => runToResult(wasmModule, profile, opts);\n"))) (ELit (LString "export default {\n"))) (ELit (LString "  async fetch(request) { return textResponse(await run()); },\n"))) (ELit (LString "};\n"))))
(DTypeSig true "edgeLoader" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "edgeLoader" ((PVar "p") (PVar "wasmFile")) (EIf (EBinOp "==" (EApp (EVar "profileName") (EVar "p")) (EVar "edgeProfileName")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import source wasmModule from ")) (EApp (EVar "display") (EApp (EVar "wasmPathLiteral") (EVar "wasmFile")))) (ELit (LString ";\n"))) (EApp (EVar "display") (EVar "loaderBody"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "edgeBytesLoader" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "edgeBytesLoader" ((PVar "p") (PVar "wasmFile")) (EIf (EBinOp "==" (EApp (EVar "profileName") (EVar "p")) (EVar "edgeProfileName")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import { readFile } from \"node:fs/promises\";\nconst wasmModule = await WebAssembly.compile(await readFile(new URL(")) (EApp (EVar "display") (EApp (EVar "wasmPathLiteral") (EVar "wasmFile")))) (ELit (LString ", import.meta.url)));\n"))) (EApp (EVar "display") (EVar "loaderBody"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "profileName" false))))
(DTypeSig false "edgeProfileName" (TyCon "String"))
(DFunDef false "edgeProfileName" () (ELit (LString "wasmgc/edge")))
(DTypeSig false "wasmPathLiteral" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "wasmPathLiteral" ((PVar "wasmFile")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EBinOp "++" (ELit (LString "./")) (EVar "wasmFile")))) (DoExpr (EApp (EVar "stringConcat") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "\""))) (EApp (EApp (EVar "escapeFrom") (EVar "arr")) (ELit (LInt 0)))) (EListLit (ELit (LString "\""))))))))
(DTypeSig false "escapeFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escapeFrom" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escapeChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EVar "escapeFrom") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "escapeChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escapeChar" ((PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (ELit (LString "\\\"")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 92))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 10))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 13))) (ELit (LString "\\r")) (EIf (EBinOp "<" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "\\u00")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "/" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 16)))) (EBinOp "+" (EBinOp "/" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 16))) (ELit (LInt 1)))) (ELit (LString "0123456789abcdef"))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "%" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 16)))) (EBinOp "+" (EBinOp "%" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 16))) (ELit (LInt 1)))) (ELit (LString "0123456789abcdef"))))) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "loaderBody" (TyCon "String"))
(DFunDef false "loaderBody" () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import { runToResult, textResponse } from \"./medaka_host.mjs\";\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "const profile = \"")) (EApp (EMethodRef "display") (EVar "edgeProfileName"))) (ELit (LString "\";\n")))) (ELit (LString "export const run = (opts = {}) => runToResult(wasmModule, profile, opts);\n"))) (ELit (LString "export default {\n"))) (ELit (LString "  async fetch(request) { return textResponse(await run()); },\n"))) (ELit (LString "};\n"))))
(DTypeSig true "edgeLoader" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "edgeLoader" ((PVar "p") (PVar "wasmFile")) (EIf (EBinOp "==" (EApp (EVar "profileName") (EVar "p")) (EVar "edgeProfileName")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import source wasmModule from ")) (EApp (EMethodRef "display") (EApp (EVar "wasmPathLiteral") (EVar "wasmFile")))) (ELit (LString ";\n"))) (EApp (EMethodRef "display") (EVar "loaderBody"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "edgeBytesLoader" (TyFun (TyCon "TargetProfile") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "edgeBytesLoader" ((PVar "p") (PVar "wasmFile")) (EIf (EBinOp "==" (EApp (EVar "profileName") (EVar "p")) (EVar "edgeProfileName")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "import { readFile } from \"node:fs/promises\";\nconst wasmModule = await WebAssembly.compile(await readFile(new URL(")) (EApp (EMethodRef "display") (EApp (EVar "wasmPathLiteral") (EVar "wasmFile")))) (ELit (LString ", import.meta.url)));\n"))) (EApp (EMethodRef "display") (EVar "loaderBody"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
