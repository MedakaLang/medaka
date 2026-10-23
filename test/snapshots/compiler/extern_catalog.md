# META
source_lines=1540
stages=DESUGAR,MARK
# SOURCE
-- The runtime extern catalog as data: one row per `stdlib/runtime.mdk` extern,
-- naming how each backend lowers it.  Design: docs/design/TARGETS-DESIGN.md §4.
--
-- A row holds no signature.  The declaration in `stdlib/runtime.mdk` is the only
-- statement of an extern's type and of the effects it requires; a consumer that
-- needs the signature joins on the name.
--
-- Each backend's column carries that backend's own family tag inside the
-- disposition.  A family names the emitter path that lowers the extern, so a
-- backend selects its emitter from its own column alone, and no backend's
-- grouping is visible in another backend's column.

import frontend.ast.{ExternDecl}

-- A loaded runtime with no declarations is still a loaded runtime. Only the
-- explicit prelude-free case states that no runtime source was loaded.
-- lint-disable-next-line rule-clone-type
public export data RuntimeExternDomain =
  | LoadedRuntimeExterns (List ExternDecl)
  | PreludeFreeRuntime

export
runtimeDomain : List ExternDecl -> RuntimeExternDomain
runtimeDomain = LoadedRuntimeExterns

import support.ordmap.{OrdMap, omEmpty, omFromPairs, omLookup}

-- Why a backend does not lower an extern.  Each kind carries its category name
-- (`gapKindName`):
--   `GapBug` (BUG): another backend lowers it, so this backend's absence is a
--     regression to fix.
--   `GapDead` (DEAD): declared, but no current stdlib path calls it.
--   `GapTodo` (TODO): lowered by no backend yet.
--   `GapPermanent` (PERMANENT): structurally unavailable on this backend.
--   `GapUnported` (WASM-GAP): a wasm lowering is possible and not yet written.
public export data GapKind =
  | GapBug
  | GapDead
  | GapTodo
  | GapPermanent
  | GapUnported

-- How one backend handles one extern.  `f` is that backend's family tag.
--
-- `CSymbol` (llvm): the lowering calls the named function of
--   `runtime/medaka_rt.c` itself.  A `_at` site twin of the symbol is the same
--   row.
-- `EnvImport` (wasm): the lowering calls the named `env` host import itself.
--   Host imports reached only through the module's own WAT runtime functions
--   are not named here; the extern is `Inline`.
-- `Inline`: lowered in place, with no runtime call of its own.
-- `Interpreted` (eval): bound in one of the interpreter's extern tables.
-- `TrapStub`: bound, but lowered to an abort instead of the extern's meaning.
-- `FrozenConstant`: bound, but to a value that is not the extern's meaning.
-- `NotProvided`: not lowered at all; the reason says why.
--
-- `TrapStub` and `FrozenConstant` are bound, so a program reaching them still
-- builds; only `NotProvided` has no binding.
public export data Disposition f =
  | CSymbol f String
  | EnvImport f String
  | Inline f
  | Interpreted
  | TrapStub f String
  | FrozenConstant f String
  | NotProvided GapKind String

-- The LLVM backend's emitter paths.  The first twenty-one are the extern
-- families `llvm_emit.mdk` dispatches a saturated call through; the last four
-- are the externs it handles by exact name elsewhere: `arrayMakeWith`'s own
-- emitter, the `Ref` cell, the constants `emitVar` writes in place, and the
-- guard fallthrough sentinel.
public export data LlvmFamily =
  | LlvmStr
  | LlvmNum
  | LlvmIo
  | LlvmAbort
  | LlvmArrIntrinsic
  | LlvmArrLeaf
  | LlvmByteBlock
  | LlvmChar
  | LlvmStrChar
  | LlvmUnicode
  | LlvmAdt
  | LlvmEnv
  | LlvmFile
  | LlvmNet
  | LlvmRng
  | LlvmHash
  | LlvmBit
  | LlvmFixedWidth
  | LlvmU64
  | LlvmDebugLit
  | LlvmPerf
  | LlvmArrayMakeWith
  | LlvmRefCell
  | LlvmConstant
  | LlvmFallthrough

-- The WasmGC backend's emitter paths: the four extern families
-- `wasm_emit.mdk`'s application ladders dispatch through, then the `Ref` cell,
-- the constants written in place, and the guard fallthrough sentinel.
public export data WasmFamily =
  | WasmStr
  | WasmLeaf
  | WasmArray
  | WasmByteBlock
  | WasmRefCell
  | WasmConstant
  | WasmFallthrough

-- A runtime demand a WasmGC lowering places on the module.  Each constructor
-- is one `WasmEmit.use*` flag of `wasm_emit.mdk`: the representation (`$str`,
-- `$arr`, the cons list, `$u64`, `$i64`), runtime function group or host
-- import block that an extern's lowering names, and so must be emitted.
-- `UseMath`, `UseClock`, `UseFloatStr` and `UseArgs` gate no flag: the host
-- imports they stand for are the extern's own host keys, which the module
-- declares and gates its runtime helpers on (`wasmHostKeys`).
public export data WasmUse =
  | UseStr
  | UseStrLeaf
  | UseRng
  | UseHash
  | UseFloat
  | UseU64
  | UseI64
  | UseMath
  | UseFloatStr
  | UseFloatHash
  | UseFloatRng
  | UseStrSearch
  | UseStrCodec
  | UseArray
  | UseList
  | UseCharFromCode
  | UseCharClass
  | UseEPut
  | UseByteBlock
  | UseArgs
  | UseFileBytes
  | UseClock
  | UseStrToInt
  | UseStrReverse
  | UseStrJoin
  deriving (Eq, Debug)

-- One extern: its name, then the llvm, wasm and eval dispositions.  The
-- interpreter selects through its own keyed tables, so its column has no family.
public export data ExternRow =
  ExternRow String (Disposition LlvmFamily) (Disposition WasmFamily) (Disposition Unit)

export
rowName : ExternRow -> String
rowName (ExternRow n _ _ _) = n

export
rowLlvm : ExternRow -> Disposition LlvmFamily
rowLlvm (ExternRow _ l _ _) = l

export
rowWasm : ExternRow -> Disposition WasmFamily
rowWasm (ExternRow _ _ w _) = w

export
rowEval : ExternRow -> Disposition Unit
rowEval (ExternRow _ _ _ v) = v

-- The family a backend selects its emitter by, or `None` when nothing is
-- lowered (`NotProvided`) or the backend has no families (`Interpreted`).
export
dispositionFamily : Disposition f -> Option f
dispositionFamily (CSymbol f _) = Some f
dispositionFamily (EnvImport f _) = Some f
dispositionFamily (Inline f) = Some f
dispositionFamily Interpreted = None
dispositionFamily (TrapStub f _) = Some f
dispositionFamily (FrozenConstant f _) = Some f
dispositionFamily (NotProvided _ _) = None

export
isBound : Disposition f -> Bool
isBound (NotProvided _ _) = False
isBound _ = True

-- The (category, reason) of a disposition that is a gap or a caveat, or `None`
-- for a binding that is the extern's meaning.
export
ledgerEntry : Disposition f -> Option (String, String)
ledgerEntry (NotProvided k why) = Some (gapKindName k, why)
ledgerEntry (TrapStub _ why) = Some ("TRAP-STUB", why)
ledgerEntry (FrozenConstant _ why) = Some ("FROZEN-CONSTANT", why)
ledgerEntry _ = None

export
gapKindName : GapKind -> String
gapKindName GapBug = "BUG"
gapKindName GapDead = "DEAD"
gapKindName GapTodo = "TODO"
gapKindName GapPermanent = "PERMANENT"
gapKindName GapUnported = "WASM-GAP"

-- The row for an extern name, or `None` for a name that is not a runtime extern.
export
catalogRow : String -> Option ExternRow
catalogRow name = omLookup name catalogIndex

-- The llvm emitter path for an extern name, or `None` for a name that is not a
-- runtime extern or has no llvm lowering.
export
llvmFamily : String -> Option LlvmFamily
llvmFamily name = match catalogRow name
  Some r => dispositionFamily (rowLlvm r)
  None => None

-- Is this llvm family one a saturated call dispatches through?  The `Ref` cell,
-- the in-place constants and the fallthrough sentinel are matched by their own
-- emit sites and are not.
export
isLlvmExternFamily : LlvmFamily -> Bool
isLlvmExternFamily LlvmRefCell = False
isLlvmExternFamily LlvmConstant = False
isLlvmExternFamily LlvmFallthrough = False
isLlvmExternFamily _ = True

-- The wasm emitter path for an extern name, or `None` for a name that is not a
-- runtime extern or has no wasm lowering.
export
wasmFamily : String -> Option WasmFamily
wasmFamily name = match catalogRow name
  Some r => dispositionFamily (rowWasm r)
  None => None

-- Is this wasm family one an application dispatches through?  The `Ref` cell,
-- the in-place constants and the fallthrough sentinel are matched by their own
-- emit sites and are not.
export
isWasmExternFamily : WasmFamily -> Bool
isWasmExternFamily WasmRefCell = False
isWasmExternFamily WasmConstant = False
isWasmExternFamily WasmFallthrough = False
isWasmExternFamily _ = True

-- Every runtime demand the wasm lowering of an extern makes, or `[]` for a
-- name with none, including a name that is not a runtime extern.
export
wasmUses : String -> List WasmUse
wasmUses name = match omLookup name wasmUseIndex
  Some us => us
  None => []

-- Every `env` host import the wasm lowering of an extern calls, or `[]` for a
-- name with none, including a name that is not a runtime extern.  An
-- `EnvImport` row's own key comes first, then the imports its WAT runtime
-- helpers call (`wasmHelperKeyRows`).
export
wasmHostKeys : String -> List String
wasmHostKeys name = match omLookup name wasmHostKeyIndex
  Some ks => ks
  None => []

catalogIndex : OrdMap ExternRow
catalogIndex = omFromPairs (map (r => (rowName r, r)) catalogRows) omEmpty

wasmUseIndex : OrdMap (List WasmUse)
wasmUseIndex = omFromPairs wasmUseRows omEmpty

wasmHostKeyIndex : OrdMap (List String)
wasmHostKeyIndex = omFromPairs (flatMap rowHostKeyPair catalogRows) omEmpty

rowHostKeyPair : ExternRow -> List (String, List String)
rowHostKeyPair r =
  let helperKeys = match omLookup (rowName r) wasmHelperKeyIndex
    Some ks => ks
    None => []
  match envImportKeys (rowWasm r) ++ helperKeys
    [] => []
    ks => [(rowName r, ks)]

envImportKeys : Disposition WasmFamily -> List String
envImportKeys (EnvImport _ key) = [key]
envImportKeys _ = []

wasmHelperKeyIndex : OrdMap (List String)
wasmHelperKeyIndex = omFromPairs wasmHelperKeyRows omEmpty

-- The `Inline` externs whose WAT runtime helpers call `env` host imports, with
-- every import those helpers call, transitively: a helper's keys include the
-- keys of each helper it calls.  An `EnvImport` row's own key is read from its
-- disposition and is not repeated here.
export
wasmHelperKeyRows : List (String, List String)
wasmHelperKeyRows = [
  ("ePutStr", ["mdk_write_err_byte"]),
  ("ePutStrLn", ["mdk_write_err_byte"]),
  ("panic", ["mdk_write_err_byte"]),
  ("indexError", ["mdk_write_err_byte"]),
  ("panicAt", ["mdk_write_err_byte"]),
  ("readFile", grantChannelKeys ++ readChannelKeys),
  ("readFileBytes", grantChannelKeys ++ readChannelKeys),
  (
    "fetchText",
    ["mdk_path_reset", "mdk_path_push", "mdk_result_len", "mdk_result_byte"],
  ),
  (
    "writeFileBytes",
    grantChannelKeys
      ++ [
        "mdk_path_reset",
        "mdk_path_push",
        "mdk_write_file_reset",
        "mdk_write_file_push",
        "mdk_write_file_commit",
        "mdk_result_len",
        "mdk_result_byte",
      ],
  ),
  (
    "writeFile",
    fileOpKeys "mdk_write_file"
      ++ ["mdk_write_file_reset", "mdk_write_file_push"],
  ),
  (
    "appendFile",
    fileOpKeys "mdk_append_file"
      ++ ["mdk_write_file_reset", "mdk_write_file_push"],
  ),
  (
    "writeFileMode",
    fileOpKeys "mdk_write_file_mode"
      ++ ["mdk_write_file_reset", "mdk_write_file_push"],
  ),
  ("rename", fileOpKeys "mdk_rename"),
  ("makeDir", fileOpKeys "mdk_make_dir"),
  ("removeFile", fileOpKeys "mdk_remove_file"),
  ("removeDir", fileOpKeys "mdk_remove_dir"),
  ("fsync", fileOpKeys "mdk_fsync"),
  ("fileMode", fileOpKeys "mdk_file_mode" ++ ["mdk_stat_field"]),
  ("listDir", fileOpKeys "mdk_list_dir"),
  ("statFile", fileOpKeys "mdk_stat_file" ++ ["mdk_stat_field"]),
  (
    "fileExists",
    grantChannelKeys ++ refusalPanicKeys ++ ["mdk_file_exists"],
  ),
  (
    "canonicalizePath",
    grantChannelKeys ++ refusalPanicKeys ++ ["mdk_canonicalize_path"],
  ),
  (
    "getEnv",
    [
      "mdk_path_reset",
      "mdk_path_push",
      "mdk_get_env",
      "mdk_result_len",
      "mdk_result_byte",
    ],
  ),
  ("args", ["mdk_args_count", "mdk_arg_len", "mdk_arg_byte"]),
  ("readLine", hostResultKeys "mdk_read_line"),
  ("readLineOpt", hostResultKeys "mdk_read_line"),
  ("readAll", hostResultKeys "mdk_read_all"),
  ("readExactly", hostResultKeys "mdk_read_exactly"),
  ("osEntropyBytes", "mdk_os_entropy" :: refusedPanicKeys),
  ("executablePath", hostResultKeys "mdk_executable_path"),
  (
    "stringToFloat",
    [
      "mdk_path_reset",
      "mdk_path_push",
      "mdk_str_to_float",
      "mdk_str_to_float_ok",
    ],
  ),
]

-- A file extern's grant goes to the host element by element, ahead of its path.
grantChannelKeys : List String
grantChannelKeys = ["mdk_grant_reset", "mdk_grant_push"]

-- A file operation that answers through the result channel: the grant and the
-- path in, the operation's own key, the result channel out.
fileOpKeys : String -> List String
fileOpKeys key =
  grantChannelKeys
    ++ [
      "mdk_path_reset", "mdk_path_push", key, "mdk_result_len",
      "mdk_result_byte"
    ]

-- the path channel in, and a refusal read from the result channel and written
-- to stderr as a panic
refusalPanicKeys : List String
refusalPanicKeys = ["mdk_path_reset", "mdk_path_push"] ++ refusedPanicKeys

-- what `$mdk_refused_panic` calls: the result channel, then the stderr writer
refusedPanicKeys : List String
refusedPanicKeys = ["mdk_result_len", "mdk_result_byte", "mdk_write_err_byte"]

-- A declared file bound (`$withFileReadBound`/`$withFileWriteBound`, which the
-- type checker writes around the body of a binding with a closed narrow file
-- row) is no extern, but its lowering pushes its grant and enters and leaves a
-- host bound frame, so a module reaching one imports these.
export
fileBoundHostKeys : List String
fileBoundHostKeys =
  grantChannelKeys ++ ["mdk_file_bound_enter", "mdk_file_bound_exit"]

-- a host call that answers through the result channel: the call, then the channel out
hostResultKeys : String -> List String
hostResultKeys key = [key, "mdk_result_len", "mdk_result_byte"]

-- the path channel in, the file read, the result channel out
readChannelKeys : List String
readChannelKeys = [
  "mdk_path_reset",
  "mdk_path_push",
  "mdk_read_file",
  "mdk_result_len",
  "mdk_result_byte",
]

-- The tuple arities an extern's wasm lowering builds, which the module must
-- declare although the program never writes a tuple of that arity.
export
wasmTupleArities : String -> List Int
wasmTupleArities "statFile" = [4]
wasmTupleArities _ = []

-- The externs whose wasm lowering demands anything, in catalog order.  Each
-- list is complete: a demand one flag implies in another (`readFileBytes`'s
-- `UseFileBytes` comes with `UseArray`) is written out, never derived.  An extern absent here demands nothing
-- beyond what its call site already brings.
export
wasmUseRows : List (String, List WasmUse)
wasmUseRows = [
  ("ePutStr", [UseEPut]),
  ("ePutStrLn", [UseEPut]),
  ("readFile", [UseStr, UseList]),
  ("readFileBytes", [UseStr, UseList, UseArray, UseFileBytes]),
  ("writeFile", [UseStr, UseList]),
  ("appendFile", [UseStr, UseList]),
  ("writeFileMode", [UseStr, UseList]),
  ("writeFileBytes", [UseStr, UseList, UseArray, UseFileBytes]),
  ("rename", [UseStr, UseList]),
  ("makeDir", [UseStr, UseList]),
  ("removeFile", [UseStr, UseList]),
  ("removeDir", [UseStr, UseList]),
  ("fsync", [UseStr, UseList]),
  ("fileMode", [UseStr, UseList]),
  ("listDir", [UseStr, UseList]),
  ("statFile", [UseStr, UseList, UseFloat]),
  ("fileExists", [UseStr, UseList]),
  ("canonicalizePath", [UseStr, UseList]),
  ("args", [UseStr, UseList, UseArgs]),
  ("getEnv", [UseStr]),
  ("readLine", [UseStr]),
  ("readLineOpt", [UseStr]),
  ("readAll", [UseStr]),
  ("readExactly", [UseStr]),
  ("osEntropyBytes", [UseStr, UseList, UseArray]),
  ("executablePath", [UseStr]),
  ("panic", [UseStr, UseEPut]),
  ("indexError", [UseStr, UseEPut]),
  ("panicAt", [UseStr, UseEPut]),
  ("wallTimeSec", [UseFloat, UseClock]),
  ("monotonicSec", [UseFloat, UseClock]),
  ("sleepMs", [UseClock]),
  ("fetchText", [UseStr, UseList]),
  ("randomInt", [UseRng]),
  ("randomBool", [UseRng]),
  ("randomFloat", [UseRng, UseFloat, UseFloatRng]),
  ("randomChar", [UseStr, UseStrLeaf, UseRng]),
  ("setSeed", [UseRng]),
  ("randomState", [UseRng, UseU64]),
  ("restoreRandomState", [UseRng, UseU64]),
  ("hashInt", [UseHash]),
  ("hashFloat", [UseHash, UseFloat, UseFloatHash]),
  ("hashString", [UseHash]),
  ("hashChar", [UseHash]),
  ("hashBool", [UseHash]),
  ("intToFloat", [UseFloat]),
  ("floatToInt", [UseFloat]),
  ("floatRem", [UseFloat]),
  ("sqrt", [UseFloat]),
  ("cbrt", [UseFloat, UseMath]),
  ("exp", [UseFloat, UseMath]),
  ("log", [UseFloat, UseMath]),
  ("log2", [UseFloat, UseMath]),
  ("log10", [UseFloat, UseMath]),
  ("sin", [UseFloat, UseMath]),
  ("cos", [UseFloat, UseMath]),
  ("tan", [UseFloat, UseMath]),
  ("asin", [UseFloat, UseMath]),
  ("acos", [UseFloat, UseMath]),
  ("atan", [UseFloat, UseMath]),
  ("sinh", [UseFloat, UseMath]),
  ("cosh", [UseFloat, UseMath]),
  ("tanh", [UseFloat, UseMath]),
  ("floor", [UseFloat]),
  ("ceil", [UseFloat]),
  ("round", [UseFloat]),
  ("trunc", [UseFloat]),
  ("pow", [UseFloat, UseMath]),
  ("atan2", [UseFloat, UseMath]),
  ("hypot", [UseFloat, UseMath]),
  ("intBitsToFloat", [UseFloat]),
  ("bytesToFloat64", [UseFloat, UseArray]),
  ("floatToBytes64", [UseFloat, UseArray]),
  ("floatToString", [UseStr, UseFloat]),
  ("debugStringLit", [UseStr, UseStrLeaf]),
  ("debugCharLit", [UseStr, UseStrLeaf]),
  ("arrayLength", [UseArray]),
  ("arrayMake", [UseArray]),
  ("arrayMakeWith", [UseArray]),
  ("arrayGetUnsafe", [UseArray]),
  ("arraySetUnsafe", [UseArray]),
  ("arrayCopy", [UseArray]),
  ("arrayBlit", [UseArray]),
  ("arrayFill", [UseArray]),
  ("arrayFromList", [UseArray, UseList]),
  ("u64Truncate", [UseU64]),
  ("u64TruncateToInt", [UseU64]),
  ("u64BitAnd", [UseU64]),
  ("u64BitOr", [UseU64]),
  ("u64BitXor", [UseU64]),
  ("u64ShiftLeft", [UseU64]),
  ("u64ShiftRight", [UseU64]),
  ("u64MulHigh", [UseU64]),
  ("i64FromBits", [UseU64, UseI64]),
  ("i64ToBits", [UseU64, UseI64]),
  ("byteBlockMake", [UseStr, UseArray, UseByteBlock]),
  ("byteBlockLength", [UseStr, UseArray, UseByteBlock]),
  ("byteBlockGetUnsafe", [UseStr, UseArray, UseByteBlock]),
  ("byteBlockSetUnsafe", [UseStr, UseArray, UseByteBlock]),
  ("byteBlockCopyUnsafe", [UseStr, UseArray, UseByteBlock]),
  ("byteBlockBlit", [UseStr, UseArray, UseByteBlock]),
  ("byteBlockFromIntArray", [UseStr, UseArray, UseByteBlock]),
  ("byteBlockToIntArray", [UseStr, UseArray, UseByteBlock]),
  ("byteBlockFromString", [UseStr, UseArray, UseByteBlock]),
  ("byteBlockToString", [UseStr, UseArray, UseByteBlock]),
  ("byteBlockWriteStdout", [UseStr, UseArray, UseByteBlock]),
  ("stringToChars", [UseStr, UseStrLeaf, UseStrCodec, UseArray]),
  ("stringFromChars", [UseStr, UseStrLeaf, UseStrCodec, UseArray]),
  ("stringToUtf8Bytes", [UseStr, UseStrCodec, UseArray]),
  ("stringFromUtf8Bytes", [UseStr, UseStrCodec, UseArray]),
  ("charToStr", [UseStrLeaf]),
  ("charFromCode", [UseCharFromCode]),
  ("stringSlice", [UseStrLeaf]),
  ("stringConcat", [UseStrLeaf]),
  ("stringIndexOf", [UseStr, UseStrLeaf, UseStrSearch]),
  ("stringStartsWith", [UseStr, UseStrLeaf]),
  ("stringEndsWith", [UseStr, UseStrLeaf]),
  ("stringCountOccurrences", [UseStr, UseStrLeaf, UseStrSearch]),
  ("stringLastIndexOf", [UseStr, UseStrLeaf, UseStrSearch]),
  ("stringToInt", [UseStr, UseStrToInt]),
  ("stringReverse", [UseStr, UseStrReverse]),
  ("stringJoin", [UseStr, UseList, UseStrJoin]),
  ("stringCompare", [UseStr, UseStrLeaf, UseStrSearch]),
  ("stringToFloat", [UseStr, UseFloat, UseFloatStr]),
  ("charIsAlpha", [UseCharClass]),
  ("charIsSpace", [UseCharClass]),
  ("charIsUpper", [UseCharClass]),
  ("charIsLower", [UseCharClass]),
  ("charIsPunct", [UseCharClass]),
  ("charToUpper", [UseCharClass]),
  ("charToLower", [UseCharClass]),
  ("stringToUpper", [UseStrLeaf]),
  ("stringToLower", [UseStrLeaf]),
]

interpLlvmOnly : String
interpLlvmOnly = "implemented by llvm, missing from the interpreter"

wasmNoSockets : String
wasmNoSockets =
  "the `net` module is native-only: raw BSD sockets have no WasmGC equivalent — build for a native target instead"

noHttpClient : String
noHttpClient =
  "`fetchText` is lowered only by the wasmgc/edge target: native has no HTTP client and no TLS — build for `wasmgc/edge`"

interpNoHttpClient : String
interpNoHttpClient =
  "the interpreter has no HTTP client; only the wasmgc/edge target lowers `fetchText`"

-- In `stdlib/runtime.mdk` declaration order.
export
catalogRows : List ExternRow
catalogRows = [
  ExternRow "putStr" (CSymbol LlvmIo "mdk_putstr") (Inline WasmStr) Interpreted,
  ExternRow
    "putStrLn"
    (CSymbol LlvmIo "mdk_putstrln")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "ePutStr"
    (CSymbol LlvmIo "mdk_eputstr")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "ePutStrLn"
    (CSymbol LlvmIo "mdk_eputstrln")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "flushStdout"
    (CSymbol LlvmIo "mdk_flushstdout")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "readLine"
    (CSymbol LlvmFile "mdk_read_line")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "readLineOpt"
    (CSymbol LlvmFile "mdk_read_line_opt")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "readAll"
    (CSymbol LlvmFile "mdk_read_all")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "readExactly"
    (CSymbol LlvmFile "mdk_read_exactly")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow "Ref" (Inline LlvmRefCell) (Inline WasmRefCell) Interpreted,
  ExternRow "setRef" (Inline LlvmRefCell) (Inline WasmRefCell) Interpreted,
  ExternRow
    "readFile"
    (CSymbol LlvmFile "mdk_read_file")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "readFileBytes"
    (CSymbol LlvmFile "mdk_read_file_bytes")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "writeFile"
    (CSymbol LlvmFile "mdk_write_file")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "writeFileBytes"
    (CSymbol LlvmFile "mdk_write_file_bytes")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "writeFileMode"
    (CSymbol LlvmFile "mdk_write_file_mode")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "appendFile"
    (CSymbol LlvmFile "mdk_append_file")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "fileExists"
    (CSymbol LlvmFile "mdk_file_exists")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "fileMode"
    (CSymbol LlvmFile "mdk_file_mode")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "canonicalizePath"
    (CSymbol LlvmFile "mdk_canonicalize_path")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "listDir"
    (CSymbol LlvmFile "mdk_list_dir")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "makeDir"
    (CSymbol LlvmFile "mdk_make_dir")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "removeFile"
    (CSymbol LlvmFile "mdk_remove_file")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "rename"
    (CSymbol LlvmFile "mdk_rename")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "fsync"
    (CSymbol LlvmFile "mdk_fsync")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "removeDir"
    (CSymbol LlvmFile "mdk_remove_dir")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "statFile"
    (CSymbol LlvmFile "mdk_stat_file")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow "args" (CSymbol LlvmEnv "mdk_args") (Inline WasmLeaf) Interpreted,
  ExternRow
    "getEnv"
    (CSymbol LlvmEnv "mdk_get_env")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "executablePath"
    (CSymbol LlvmFile "mdk_executable_path")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "buildFingerprint"
    (CSymbol LlvmFile "mdk_build_fingerprint")
    (NotProvided
      GapPermanent
      "build-provenance (the staleness guard) is meaningless in the WasmGC playground — there is no build-provenance object linked in and no host filesystem to re-hash compiler/ against; the compiler is only ever built via the LLVM backend, never wasm")
    Interpreted,
  ExternRow
    "buildCommit"
    (CSymbol LlvmFile "mdk_build_commit")
    (NotProvided
      GapPermanent
      "same rationale as buildFingerprint (a sibling provenance stamp) — no build-provenance object linked in and no host git checkout in the WasmGC playground")
    Interpreted,
  ExternRow
    "buildDate"
    (CSymbol LlvmFile "mdk_build_date")
    (NotProvided
      GapPermanent
      "same rationale as buildFingerprint (a sibling provenance stamp) — no build-provenance object linked into the WasmGC playground")
    Interpreted,
  ExternRow
    "runCommand"
    (CSymbol LlvmFile "mdk_run_command")
    (NotProvided
      GapPermanent
      "a subprocess has no WasmGC host equivalent: Exec is granted on native and run only, and no wasm profile grants it")
    (NotProvided
      GapBug
      "implemented by llvm, missing from the interpreter on purpose: the interpreter waits on a decision about the --allow-exec security posture"),
  ExternRow
    "runCommandBatch"
    (CSymbol LlvmFile "mdk_run_command_batch")
    (NotProvided
      GapPermanent
      "a subprocess has no WasmGC host equivalent: Exec is granted on native and run only, and no wasm profile grants it")
    (NotProvided
      GapBug
      "implemented by llvm, missing from the interpreter on purpose: the same --allow-exec posture as runCommand"),
  ExternRow
    "exit"
    (CSymbol LlvmAbort "mdk_exit")
    (EnvImport WasmLeaf "mdk_exit")
    Interpreted,
  ExternRow
    "panic"
    (CSymbol LlvmAbort "mdk_panic")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "indexError"
    (CSymbol LlvmAbort "mdk_oob_msg")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "indexErrorAt"
    (CSymbol LlvmAbort "mdk_oob_at")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "indexErrorAtSite"
    (CSymbol LlvmAbort "mdk_oob_at")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "panicAt"
    (CSymbol LlvmAbort "mdk_panic")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "sliceError"
    (CSymbol LlvmAbort "mdk_slice_oob")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "stashRunStdout"
    (CSymbol LlvmIo "mdk_stash_run_stdout")
    (NotProvided
      GapPermanent
      "internal `medaka run` CLI plumbing (interpreter-only outputRef stash for the \"run drops stdout on panic\" fix) — the compiler is only ever built via the LLVM backend, never wasm, so no WasmGC program ever exercises this")
    Interpreted,
  ExternRow
    "enableRunStdoutFlush"
    (CSymbol LlvmIo "mdk_enable_run_stdout_flush")
    (NotProvided
      GapPermanent
      "internal `medaka run` CLI plumbing (arms the abort-time flush for the \"run drops stdout on panic\" fix) — the compiler is only ever built via the LLVM backend, never wasm, so no WasmGC program ever exercises this")
    Interpreted,
  ExternRow
    "__fallthrough__"
    (Inline LlvmFallthrough)
    (Inline WasmFallthrough)
    Interpreted,
  ExternRow
    "assertSnapshot"
    (NotProvided
      GapTodo
      "unimplemented in all 3 engines, no stdlib caller — forward-declared snapshot-testing primitive, not an asymmetric regression")
    (NotProvided
      GapTodo
      "unimplemented in all 3 engines, no stdlib caller — forward-declared snapshot-testing primitive, not an asymmetric regression")
    (NotProvided
      GapBug
      "unimplemented in all 3 engines (see llvm/wasm TODO rows); no stdlib caller yet — a forward-declared snapshot-testing primitive (TESTING-DESIGN.md §4.7 \"medaka test --promote\"); recorded as a bug row for the interpreter although it is not an asymmetric regression against another engine"),
  ExternRow
    "netResolve"
    (CSymbol LlvmNet "mdk_net_resolve")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netTcpConnect"
    (CSymbol LlvmNet "mdk_net_tcp_connect")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netTcpListen"
    (CSymbol LlvmNet "mdk_net_tcp_listen")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netListenPort"
    (CSymbol LlvmNet "mdk_net_listen_port")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netTcpAccept"
    (CSymbol LlvmNet "mdk_net_tcp_accept")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netSend"
    (CSymbol LlvmNet "mdk_net_send")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netSendFrom"
    (CSymbol LlvmNet "mdk_net_send_from")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netRecv"
    (CSymbol LlvmNet "mdk_net_recv")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netShutdown"
    (CSymbol LlvmNet "mdk_net_shutdown")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netClose"
    (CSymbol LlvmNet "mdk_net_close")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netCloseListener"
    (CSymbol LlvmNet "mdk_net_close")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netSetTimeout"
    (CSymbol LlvmNet "mdk_net_set_timeout")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "socketFd"
    (Inline LlvmNet)
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "listenSocketFd"
    (Inline LlvmNet)
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "pdsSignalStart"
    (CSymbol LlvmNet "mdk_pds_signal_start")
    (NotProvided
      GapPermanent
      "POSIX SIGTERM self-pipe and fd readiness are native-only; wasm_emit rejects the net family")
    (NotProvided
      GapBug
      "the interpreter has no signal host binding yet, though the run profile grants Signal (TARGETS-DESIGN §8.1)"),
  ExternRow
    "pdsSignalRequested"
    (CSymbol LlvmNet "mdk_pds_signal_requested")
    (NotProvided
      GapPermanent
      "POSIX SIGTERM state is native-only; wasm_emit rejects the net family")
    (NotProvided
      GapBug
      "the interpreter has no signal host binding yet, though the run profile grants Signal (TARGETS-DESIGN §8.1)"),
  ExternRow
    "ioPoll"
    (CSymbol LlvmNet "mdk_io_poll")
    (TrapStub
      WasmLeaf
      "bound to a coded runtime trap, not a value: E-WASM-NO-BINDING after evaluating its arguments; the Net/Stdin readiness bindings are #3666")
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netSetNonblock"
    (CSymbol LlvmNet "mdk_net_set_nonblock")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netSetNonblockListener"
    (CSymbol LlvmNet "mdk_net_set_nonblock")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netTryAccept"
    (CSymbol LlvmNet "mdk_net_try_accept")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netConnectStart"
    (CSymbol LlvmNet "mdk_net_connect_start")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netConnectCheck"
    (CSymbol LlvmNet "mdk_net_connect_check")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netTryRecv"
    (CSymbol LlvmNet "mdk_net_try_recv")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netTryRecvBytes"
    (CSymbol LlvmNet "mdk_net_try_recv_bytes")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netTrySend"
    (CSymbol LlvmNet "mdk_net_try_send")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netTrySendFrom"
    (CSymbol LlvmNet "mdk_net_try_send_from")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netSendBytesFrom"
    (CSymbol LlvmNet "mdk_net_send_bytes_from")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "netTrySendBytesFrom"
    (CSymbol LlvmNet "mdk_net_try_send_bytes_from")
    (NotProvided GapPermanent wasmNoSockets)
    (NotProvided GapBug interpLlvmOnly),
  ExternRow
    "wallTimeSec"
    (CSymbol LlvmPerf "mdk_wall_time_sec")
    (EnvImport WasmLeaf "mdk_wall_time_sec")
    Interpreted,
  ExternRow
    "monotonicSec"
    (CSymbol LlvmPerf "mdk_monotonic_sec")
    (EnvImport WasmLeaf "mdk_monotonic_sec")
    Interpreted,
  ExternRow
    "sleepMs"
    (CSymbol LlvmPerf "mdk_sleep_ms")
    (EnvImport WasmLeaf "mdk_sleep_ms")
    Interpreted,
  ExternRow
    "fetchText"
    (NotProvided GapPermanent noHttpClient)
    (EnvImport WasmLeaf "mdk_fetch_text")
    (NotProvided GapPermanent interpNoHttpClient),
  ExternRow
    "allocBytes"
    (CSymbol LlvmPerf "mdk_alloc_bytes")
    (NotProvided
      GapUnported
      "real GC-byte-counter FFI in llvm, no wasm host-import wired")
    Interpreted,
  ExternRow
    "randomInt"
    (CSymbol LlvmRng "mdk_random_int")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "randomBool"
    (CSymbol LlvmRng "mdk_random_bool")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "randomFloat"
    (CSymbol LlvmRng "mdk_random_float")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "randomChar"
    (CSymbol LlvmRng "mdk_random_char")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "setSeed"
    (CSymbol LlvmRng "mdk_set_seed")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "randomState"
    (CSymbol LlvmRng "mdk_random_state")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "restoreRandomState"
    (CSymbol LlvmRng "mdk_restore_random_state")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "osEntropyBytes"
    (CSymbol LlvmRng "mdk_os_entropy_bytes")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "hashInt"
    (CSymbol LlvmHash "mdk_hash_int")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "hashFloat"
    (CSymbol LlvmHash "mdk_hash_float")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "hashString"
    (CSymbol LlvmHash "mdk_hash_string")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "hashChar"
    (CSymbol LlvmHash "mdk_hash_char")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "hashBool"
    (CSymbol LlvmHash "mdk_hash_bool")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow "pi" (Inline LlvmConstant) (Inline WasmConstant) Interpreted,
  ExternRow "e" (Inline LlvmConstant) (Inline WasmConstant) Interpreted,
  ExternRow
    "intMinBound"
    (Inline LlvmConstant)
    (Inline WasmConstant)
    Interpreted,
  ExternRow
    "intMaxBound"
    (Inline LlvmConstant)
    (Inline WasmConstant)
    Interpreted,
  ExternRow
    "charMinBound"
    (Inline LlvmConstant)
    (Inline WasmConstant)
    Interpreted,
  ExternRow
    "charMaxBound"
    (Inline LlvmConstant)
    (Inline WasmConstant)
    Interpreted,
  ExternRow "intToFloat" (Inline LlvmNum) (Inline WasmLeaf) Interpreted,
  ExternRow "floatToInt" (Inline LlvmNum) (Inline WasmLeaf) Interpreted,
  ExternRow
    "floatRem"
    (CSymbol LlvmNum "mdk_float_rem")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "bitAnd"
    (CSymbol LlvmBit "mdk_bit_and")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "bitOr"
    (CSymbol LlvmBit "mdk_bit_or")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "bitXor"
    (CSymbol LlvmBit "mdk_bit_xor")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "shiftLeft"
    (CSymbol LlvmBit "mdk_shift_left")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "shiftRight"
    (CSymbol LlvmBit "mdk_shift_right")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "bitNot"
    (CSymbol LlvmBit "mdk_bit_not")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow "sqrt" (CSymbol LlvmNum "mdk_sqrt") (Inline WasmLeaf) Interpreted,
  ExternRow
    "cbrt"
    (CSymbol LlvmNum "mdk_cbrt")
    (EnvImport WasmLeaf "mdk_cbrt")
    Interpreted,
  ExternRow
    "exp"
    (CSymbol LlvmNum "mdk_exp")
    (EnvImport WasmLeaf "mdk_exp")
    Interpreted,
  ExternRow
    "log"
    (CSymbol LlvmNum "mdk_log")
    (EnvImport WasmLeaf "mdk_log")
    Interpreted,
  ExternRow
    "log2"
    (CSymbol LlvmNum "mdk_log2")
    (EnvImport WasmLeaf "mdk_log2")
    Interpreted,
  ExternRow
    "log10"
    (CSymbol LlvmNum "mdk_log10")
    (EnvImport WasmLeaf "mdk_log10")
    Interpreted,
  ExternRow
    "sin"
    (CSymbol LlvmNum "mdk_sin")
    (EnvImport WasmLeaf "mdk_sin")
    Interpreted,
  ExternRow
    "cos"
    (CSymbol LlvmNum "mdk_cos")
    (EnvImport WasmLeaf "mdk_cos")
    Interpreted,
  ExternRow
    "tan"
    (CSymbol LlvmNum "mdk_tan")
    (EnvImport WasmLeaf "mdk_tan")
    Interpreted,
  ExternRow
    "asin"
    (CSymbol LlvmNum "mdk_asin")
    (EnvImport WasmLeaf "mdk_asin")
    Interpreted,
  ExternRow
    "acos"
    (CSymbol LlvmNum "mdk_acos")
    (EnvImport WasmLeaf "mdk_acos")
    Interpreted,
  ExternRow
    "atan"
    (CSymbol LlvmNum "mdk_atan")
    (EnvImport WasmLeaf "mdk_atan")
    Interpreted,
  ExternRow
    "sinh"
    (CSymbol LlvmNum "mdk_sinh")
    (EnvImport WasmLeaf "mdk_sinh")
    Interpreted,
  ExternRow
    "cosh"
    (CSymbol LlvmNum "mdk_cosh")
    (EnvImport WasmLeaf "mdk_cosh")
    Interpreted,
  ExternRow
    "tanh"
    (CSymbol LlvmNum "mdk_tanh")
    (EnvImport WasmLeaf "mdk_tanh")
    Interpreted,
  ExternRow "floor" (CSymbol LlvmNum "mdk_floor") (Inline WasmLeaf) Interpreted,
  ExternRow "ceil" (CSymbol LlvmNum "mdk_ceil") (Inline WasmLeaf) Interpreted,
  ExternRow "round" (CSymbol LlvmNum "mdk_round") (Inline WasmLeaf) Interpreted,
  ExternRow "trunc" (CSymbol LlvmNum "mdk_trunc") (Inline WasmLeaf) Interpreted,
  ExternRow
    "pow"
    (CSymbol LlvmNum "mdk_pow")
    (EnvImport WasmLeaf "mdk_pow")
    Interpreted,
  ExternRow
    "atan2"
    (CSymbol LlvmNum "mdk_atan2")
    (EnvImport WasmLeaf "mdk_atan2")
    Interpreted,
  ExternRow
    "hypot"
    (CSymbol LlvmNum "mdk_hypot")
    (EnvImport WasmLeaf "mdk_hypot")
    Interpreted,
  ExternRow
    "intBitsToFloat"
    (CSymbol LlvmNum "mdk_int_bits_to_float")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "bytesToFloat64"
    (CSymbol LlvmNum "mdk_bytes_to_float64")
    (Inline WasmArray)
    Interpreted,
  ExternRow
    "floatToBytes64"
    (CSymbol LlvmNum "mdk_float_to_bytes64")
    (Inline WasmArray)
    Interpreted,
  ExternRow
    "intToString"
    (CSymbol LlvmStr "mdk_int_to_string")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "floatToString"
    (CSymbol LlvmNum "mdk_float_to_string")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "debugStringLit"
    (CSymbol LlvmDebugLit "mdk_debug_string_lit")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "debugCharLit"
    (CSymbol LlvmDebugLit "mdk_debug_char_lit")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "arrayLength"
    (Inline LlvmArrIntrinsic)
    (Inline WasmArray)
    Interpreted,
  ExternRow
    "arrayMake"
    (CSymbol LlvmArrLeaf "mdk_array_make")
    (Inline WasmArray)
    Interpreted,
  ExternRow
    "arrayMakeWith"
    (Inline LlvmArrayMakeWith)
    (Inline WasmArray)
    Interpreted,
  ExternRow
    "arrayGetUnsafe"
    (Inline LlvmArrIntrinsic)
    (Inline WasmArray)
    Interpreted,
  ExternRow
    "arraySetUnsafe"
    (Inline LlvmArrIntrinsic)
    (Inline WasmArray)
    Interpreted,
  ExternRow
    "arrayCopy"
    (CSymbol LlvmArrLeaf "mdk_array_copy")
    (Inline WasmArray)
    Interpreted,
  ExternRow
    "arrayBlit"
    (CSymbol LlvmArrLeaf "mdk_array_blit")
    (Inline WasmArray)
    Interpreted,
  ExternRow
    "arrayFill"
    (CSymbol LlvmArrLeaf "mdk_array_fill")
    (Inline WasmArray)
    Interpreted,
  ExternRow
    "arrayFromList"
    (CSymbol LlvmArrLeaf "mdk_array_from_list")
    (Inline WasmArray)
    Interpreted,
  ExternRow "u8Truncate" (Inline LlvmFixedWidth) (Inline WasmLeaf) Interpreted,
  ExternRow "u8ToInt" (Inline LlvmFixedWidth) (Inline WasmLeaf) Interpreted,
  ExternRow "u16Truncate" (Inline LlvmFixedWidth) (Inline WasmLeaf) Interpreted,
  ExternRow "u16ToInt" (Inline LlvmFixedWidth) (Inline WasmLeaf) Interpreted,
  ExternRow "u32Truncate" (Inline LlvmFixedWidth) (Inline WasmLeaf) Interpreted,
  ExternRow "u32ToInt" (Inline LlvmFixedWidth) (Inline WasmLeaf) Interpreted,
  ExternRow
    "intBitAnd"
    (CSymbol LlvmBit "mdk_bit_and")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "intBitOr"
    (CSymbol LlvmBit "mdk_bit_or")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "intBitXor"
    (CSymbol LlvmBit "mdk_bit_xor")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "intBitNot"
    (CSymbol LlvmBit "mdk_bit_not")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "intShiftLeft"
    (CSymbol LlvmBit "mdk_shift_left")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "intShiftRight"
    (CSymbol LlvmBit "mdk_shift_right")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow "u64Truncate" (Inline LlvmU64) (Inline WasmLeaf) Interpreted,
  ExternRow "u64TruncateToInt" (Inline LlvmU64) (Inline WasmLeaf) Interpreted,
  ExternRow "u64BitAnd" (Inline LlvmU64) (Inline WasmLeaf) Interpreted,
  ExternRow "u64BitOr" (Inline LlvmU64) (Inline WasmLeaf) Interpreted,
  ExternRow "u64BitXor" (Inline LlvmU64) (Inline WasmLeaf) Interpreted,
  ExternRow "u64ShiftLeft" (Inline LlvmU64) (Inline WasmLeaf) Interpreted,
  ExternRow "u64ShiftRight" (Inline LlvmU64) (Inline WasmLeaf) Interpreted,
  ExternRow "u64MulHigh" (Inline LlvmU64) (Inline WasmLeaf) Interpreted,
  ExternRow "i32Truncate" (Inline LlvmFixedWidth) (Inline WasmLeaf) Interpreted,
  ExternRow "i32ToInt" (Inline LlvmFixedWidth) (Inline WasmLeaf) Interpreted,
  ExternRow "i64FromBits" (Inline LlvmU64) (Inline WasmLeaf) Interpreted,
  ExternRow "i64ToBits" (Inline LlvmU64) (Inline WasmLeaf) Interpreted,
  ExternRow
    "byteBlockMake"
    (CSymbol LlvmByteBlock "mdk_byteblock_make")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "byteBlockLength"
    (CSymbol LlvmByteBlock "mdk_byteblock_length")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "byteBlockGetUnsafe"
    (CSymbol LlvmByteBlock "mdk_byteblock_get")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "byteBlockSetUnsafe"
    (CSymbol LlvmByteBlock "mdk_byteblock_set")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "byteBlockCopyUnsafe"
    (CSymbol LlvmByteBlock "mdk_byteblock_copy")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "byteBlockBlit"
    (CSymbol LlvmByteBlock "mdk_byteblock_blit")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "byteBlockFromIntArray"
    (CSymbol LlvmByteBlock "mdk_byteblock_from_int_array")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "byteBlockToIntArray"
    (CSymbol LlvmByteBlock "mdk_byteblock_to_int_array")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "byteBlockFromString"
    (CSymbol LlvmByteBlock "mdk_byteblock_from_string")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "byteBlockToString"
    (CSymbol LlvmByteBlock "mdk_byteblock_to_string")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "byteBlockWriteStdout"
    (CSymbol LlvmIo "mdk_byteblock_write_stdout")
    (Inline WasmByteBlock)
    Interpreted,
  ExternRow
    "stringToChars"
    (CSymbol LlvmStrChar "mdk_string_to_chars")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringFromChars"
    (CSymbol LlvmStrChar "mdk_string_from_chars")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringToUtf8Bytes"
    (CSymbol LlvmStrChar "mdk_string_to_utf8_bytes")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringFromUtf8Bytes"
    (CSymbol LlvmStrChar "mdk_string_from_utf8_bytes")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "charToStr"
    (CSymbol LlvmChar "mdk_char_to_str")
    (Inline WasmStr)
    Interpreted,
  ExternRow "charCode" (Inline LlvmChar) (Inline WasmLeaf) Interpreted,
  ExternRow
    "charFromCode"
    (CSymbol LlvmAdt "mdk_char_from_code")
    (Inline WasmStr)
    Interpreted,
  ExternRow "stringLength" (Inline LlvmStr) (Inline WasmStr) Interpreted,
  ExternRow "stringByteLength" (Inline LlvmStr) (Inline WasmStr) Interpreted,
  ExternRow
    "stringSlice"
    (CSymbol LlvmStrChar "mdk_string_slice")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringConcat"
    (CSymbol LlvmStr "mdk_string_concat")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringIndexOf"
    (CSymbol LlvmAdt "mdk_string_index_of")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringStartsWith"
    (CSymbol LlvmStr "mdk_string_starts_with")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringEndsWith"
    (CSymbol LlvmStr "mdk_string_ends_with")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringCountOccurrences"
    (CSymbol LlvmStr "mdk_string_count_occurrences")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringLastIndexOf"
    (CSymbol LlvmAdt "mdk_string_last_index_of")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringToInt"
    (CSymbol LlvmAdt "mdk_string_to_int")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringReverse"
    (CSymbol LlvmStr "mdk_string_reverse")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringJoin"
    (CSymbol LlvmStr "mdk_string_join")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringCompare"
    (CSymbol LlvmAdt "mdk_string_compare")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringToFloat"
    (CSymbol LlvmAdt "mdk_string_to_float")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "charIsAlpha"
    (CSymbol LlvmUnicode "mdk_char_is_alpha")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "charIsSpace"
    (CSymbol LlvmUnicode "mdk_char_is_space")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "charIsUpper"
    (CSymbol LlvmUnicode "mdk_char_is_upper")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "charIsLower"
    (CSymbol LlvmUnicode "mdk_char_is_lower")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "charIsPunct"
    (CSymbol LlvmUnicode "mdk_char_is_punct")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "charToUpper"
    (CSymbol LlvmUnicode "mdk_char_to_upper")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "charToLower"
    (CSymbol LlvmUnicode "mdk_char_to_lower")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "stringToUpper"
    (CSymbol LlvmUnicode "mdk_string_to_upper")
    (Inline WasmStr)
    Interpreted,
  ExternRow
    "stringToLower"
    (CSymbol LlvmUnicode "mdk_string_to_lower")
    (Inline WasmStr)
    Interpreted,
]
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "ExternDecl" false))))
(DData Public "RuntimeExternDomain" () ((variant "LoadedRuntimeExterns" (ConPos (TyApp (TyCon "List") (TyCon "ExternDecl")))) (variant "PreludeFreeRuntime" (ConPos))) ())
(DTypeSig true "runtimeDomain" (TyFun (TyApp (TyCon "List") (TyCon "ExternDecl")) (TyCon "RuntimeExternDomain")))
(DFunDef false "runtimeDomain" () (EVar "LoadedRuntimeExterns"))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omLookup" false))))
(DData Public "GapKind" () ((variant "GapBug" (ConPos)) (variant "GapDead" (ConPos)) (variant "GapTodo" (ConPos)) (variant "GapPermanent" (ConPos)) (variant "GapUnported" (ConPos))) ())
(DData Public "Disposition" ("f") ((variant "CSymbol" (ConPos (TyVar "f") (TyCon "String"))) (variant "EnvImport" (ConPos (TyVar "f") (TyCon "String"))) (variant "Inline" (ConPos (TyVar "f"))) (variant "Interpreted" (ConPos)) (variant "TrapStub" (ConPos (TyVar "f") (TyCon "String"))) (variant "FrozenConstant" (ConPos (TyVar "f") (TyCon "String"))) (variant "NotProvided" (ConPos (TyCon "GapKind") (TyCon "String")))) ())
(DData Public "LlvmFamily" () ((variant "LlvmStr" (ConPos)) (variant "LlvmNum" (ConPos)) (variant "LlvmIo" (ConPos)) (variant "LlvmAbort" (ConPos)) (variant "LlvmArrIntrinsic" (ConPos)) (variant "LlvmArrLeaf" (ConPos)) (variant "LlvmByteBlock" (ConPos)) (variant "LlvmChar" (ConPos)) (variant "LlvmStrChar" (ConPos)) (variant "LlvmUnicode" (ConPos)) (variant "LlvmAdt" (ConPos)) (variant "LlvmEnv" (ConPos)) (variant "LlvmFile" (ConPos)) (variant "LlvmNet" (ConPos)) (variant "LlvmRng" (ConPos)) (variant "LlvmHash" (ConPos)) (variant "LlvmBit" (ConPos)) (variant "LlvmFixedWidth" (ConPos)) (variant "LlvmU64" (ConPos)) (variant "LlvmDebugLit" (ConPos)) (variant "LlvmPerf" (ConPos)) (variant "LlvmArrayMakeWith" (ConPos)) (variant "LlvmRefCell" (ConPos)) (variant "LlvmConstant" (ConPos)) (variant "LlvmFallthrough" (ConPos))) ())
(DData Public "WasmFamily" () ((variant "WasmStr" (ConPos)) (variant "WasmLeaf" (ConPos)) (variant "WasmArray" (ConPos)) (variant "WasmByteBlock" (ConPos)) (variant "WasmRefCell" (ConPos)) (variant "WasmConstant" (ConPos)) (variant "WasmFallthrough" (ConPos))) ())
(DData Public "WasmUse" () ((variant "UseStr" (ConPos)) (variant "UseStrLeaf" (ConPos)) (variant "UseRng" (ConPos)) (variant "UseHash" (ConPos)) (variant "UseFloat" (ConPos)) (variant "UseU64" (ConPos)) (variant "UseI64" (ConPos)) (variant "UseMath" (ConPos)) (variant "UseFloatStr" (ConPos)) (variant "UseFloatHash" (ConPos)) (variant "UseFloatRng" (ConPos)) (variant "UseStrSearch" (ConPos)) (variant "UseStrCodec" (ConPos)) (variant "UseArray" (ConPos)) (variant "UseList" (ConPos)) (variant "UseCharFromCode" (ConPos)) (variant "UseCharClass" (ConPos)) (variant "UseEPut" (ConPos)) (variant "UseByteBlock" (ConPos)) (variant "UseArgs" (ConPos)) (variant "UseFileBytes" (ConPos)) (variant "UseClock" (ConPos)) (variant "UseStrToInt" (ConPos)) (variant "UseStrReverse" (ConPos)) (variant "UseStrJoin" (ConPos))) ())
(DImpl true "Eq" ((TyCon "WasmUse")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "UseStr") (PCon "UseStr")) () (EVar "True")) (arm (PTuple (PCon "UseStrLeaf") (PCon "UseStrLeaf")) () (EVar "True")) (arm (PTuple (PCon "UseRng") (PCon "UseRng")) () (EVar "True")) (arm (PTuple (PCon "UseHash") (PCon "UseHash")) () (EVar "True")) (arm (PTuple (PCon "UseFloat") (PCon "UseFloat")) () (EVar "True")) (arm (PTuple (PCon "UseU64") (PCon "UseU64")) () (EVar "True")) (arm (PTuple (PCon "UseI64") (PCon "UseI64")) () (EVar "True")) (arm (PTuple (PCon "UseMath") (PCon "UseMath")) () (EVar "True")) (arm (PTuple (PCon "UseFloatStr") (PCon "UseFloatStr")) () (EVar "True")) (arm (PTuple (PCon "UseFloatHash") (PCon "UseFloatHash")) () (EVar "True")) (arm (PTuple (PCon "UseFloatRng") (PCon "UseFloatRng")) () (EVar "True")) (arm (PTuple (PCon "UseStrSearch") (PCon "UseStrSearch")) () (EVar "True")) (arm (PTuple (PCon "UseStrCodec") (PCon "UseStrCodec")) () (EVar "True")) (arm (PTuple (PCon "UseArray") (PCon "UseArray")) () (EVar "True")) (arm (PTuple (PCon "UseList") (PCon "UseList")) () (EVar "True")) (arm (PTuple (PCon "UseCharFromCode") (PCon "UseCharFromCode")) () (EVar "True")) (arm (PTuple (PCon "UseCharClass") (PCon "UseCharClass")) () (EVar "True")) (arm (PTuple (PCon "UseEPut") (PCon "UseEPut")) () (EVar "True")) (arm (PTuple (PCon "UseByteBlock") (PCon "UseByteBlock")) () (EVar "True")) (arm (PTuple (PCon "UseArgs") (PCon "UseArgs")) () (EVar "True")) (arm (PTuple (PCon "UseFileBytes") (PCon "UseFileBytes")) () (EVar "True")) (arm (PTuple (PCon "UseClock") (PCon "UseClock")) () (EVar "True")) (arm (PTuple (PCon "UseStrToInt") (PCon "UseStrToInt")) () (EVar "True")) (arm (PTuple (PCon "UseStrReverse") (PCon "UseStrReverse")) () (EVar "True")) (arm (PTuple (PCon "UseStrJoin") (PCon "UseStrJoin")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "WasmUse")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "UseStr") () (ELit (LString "UseStr"))) (arm (PCon "UseStrLeaf") () (ELit (LString "UseStrLeaf"))) (arm (PCon "UseRng") () (ELit (LString "UseRng"))) (arm (PCon "UseHash") () (ELit (LString "UseHash"))) (arm (PCon "UseFloat") () (ELit (LString "UseFloat"))) (arm (PCon "UseU64") () (ELit (LString "UseU64"))) (arm (PCon "UseI64") () (ELit (LString "UseI64"))) (arm (PCon "UseMath") () (ELit (LString "UseMath"))) (arm (PCon "UseFloatStr") () (ELit (LString "UseFloatStr"))) (arm (PCon "UseFloatHash") () (ELit (LString "UseFloatHash"))) (arm (PCon "UseFloatRng") () (ELit (LString "UseFloatRng"))) (arm (PCon "UseStrSearch") () (ELit (LString "UseStrSearch"))) (arm (PCon "UseStrCodec") () (ELit (LString "UseStrCodec"))) (arm (PCon "UseArray") () (ELit (LString "UseArray"))) (arm (PCon "UseList") () (ELit (LString "UseList"))) (arm (PCon "UseCharFromCode") () (ELit (LString "UseCharFromCode"))) (arm (PCon "UseCharClass") () (ELit (LString "UseCharClass"))) (arm (PCon "UseEPut") () (ELit (LString "UseEPut"))) (arm (PCon "UseByteBlock") () (ELit (LString "UseByteBlock"))) (arm (PCon "UseArgs") () (ELit (LString "UseArgs"))) (arm (PCon "UseFileBytes") () (ELit (LString "UseFileBytes"))) (arm (PCon "UseClock") () (ELit (LString "UseClock"))) (arm (PCon "UseStrToInt") () (ELit (LString "UseStrToInt"))) (arm (PCon "UseStrReverse") () (ELit (LString "UseStrReverse"))) (arm (PCon "UseStrJoin") () (ELit (LString "UseStrJoin")))))))
(DData Public "ExternRow" () ((variant "ExternRow" (ConPos (TyCon "String") (TyApp (TyCon "Disposition") (TyCon "LlvmFamily")) (TyApp (TyCon "Disposition") (TyCon "WasmFamily")) (TyApp (TyCon "Disposition") (TyCon "Unit"))))) ())
(DTypeSig true "rowName" (TyFun (TyCon "ExternRow") (TyCon "String")))
(DFunDef false "rowName" ((PCon "ExternRow" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig true "rowLlvm" (TyFun (TyCon "ExternRow") (TyApp (TyCon "Disposition") (TyCon "LlvmFamily"))))
(DFunDef false "rowLlvm" ((PCon "ExternRow" PWild (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig true "rowWasm" (TyFun (TyCon "ExternRow") (TyApp (TyCon "Disposition") (TyCon "WasmFamily"))))
(DFunDef false "rowWasm" ((PCon "ExternRow" PWild PWild (PVar "w") PWild)) (EVar "w"))
(DTypeSig true "rowEval" (TyFun (TyCon "ExternRow") (TyApp (TyCon "Disposition") (TyCon "Unit"))))
(DFunDef false "rowEval" ((PCon "ExternRow" PWild PWild PWild (PVar "v"))) (EVar "v"))
(DTypeSig true "dispositionFamily" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyApp (TyCon "Option") (TyVar "f"))))
(DFunDef false "dispositionFamily" ((PCon "CSymbol" (PVar "f") PWild)) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "dispositionFamily" ((PCon "EnvImport" (PVar "f") PWild)) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "dispositionFamily" ((PCon "Inline" (PVar "f"))) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "dispositionFamily" ((PCon "Interpreted")) (EVar "None"))
(DFunDef false "dispositionFamily" ((PCon "TrapStub" (PVar "f") PWild)) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "dispositionFamily" ((PCon "FrozenConstant" (PVar "f") PWild)) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "dispositionFamily" ((PCon "NotProvided" PWild PWild)) (EVar "None"))
(DTypeSig true "isBound" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyCon "Bool")))
(DFunDef false "isBound" ((PCon "NotProvided" PWild PWild)) (EVar "False"))
(DFunDef false "isBound" (PWild) (EVar "True"))
(DTypeSig true "ledgerEntry" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "ledgerEntry" ((PCon "NotProvided" (PVar "k") (PVar "why"))) (EApp (EVar "Some") (ETuple (EApp (EVar "gapKindName") (EVar "k")) (EVar "why"))))
(DFunDef false "ledgerEntry" ((PCon "TrapStub" PWild (PVar "why"))) (EApp (EVar "Some") (ETuple (ELit (LString "TRAP-STUB")) (EVar "why"))))
(DFunDef false "ledgerEntry" ((PCon "FrozenConstant" PWild (PVar "why"))) (EApp (EVar "Some") (ETuple (ELit (LString "FROZEN-CONSTANT")) (EVar "why"))))
(DFunDef false "ledgerEntry" (PWild) (EVar "None"))
(DTypeSig true "gapKindName" (TyFun (TyCon "GapKind") (TyCon "String")))
(DFunDef false "gapKindName" ((PCon "GapBug")) (ELit (LString "BUG")))
(DFunDef false "gapKindName" ((PCon "GapDead")) (ELit (LString "DEAD")))
(DFunDef false "gapKindName" ((PCon "GapTodo")) (ELit (LString "TODO")))
(DFunDef false "gapKindName" ((PCon "GapPermanent")) (ELit (LString "PERMANENT")))
(DFunDef false "gapKindName" ((PCon "GapUnported")) (ELit (LString "WASM-GAP")))
(DTypeSig true "catalogRow" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "ExternRow"))))
(DFunDef false "catalogRow" ((PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "catalogIndex")))
(DTypeSig true "llvmFamily" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "LlvmFamily"))))
(DFunDef false "llvmFamily" ((PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "dispositionFamily") (EApp (EVar "rowLlvm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "isLlvmExternFamily" (TyFun (TyCon "LlvmFamily") (TyCon "Bool")))
(DFunDef false "isLlvmExternFamily" ((PCon "LlvmRefCell")) (EVar "False"))
(DFunDef false "isLlvmExternFamily" ((PCon "LlvmConstant")) (EVar "False"))
(DFunDef false "isLlvmExternFamily" ((PCon "LlvmFallthrough")) (EVar "False"))
(DFunDef false "isLlvmExternFamily" (PWild) (EVar "True"))
(DTypeSig true "wasmFamily" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "WasmFamily"))))
(DFunDef false "wasmFamily" ((PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "dispositionFamily") (EApp (EVar "rowWasm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "isWasmExternFamily" (TyFun (TyCon "WasmFamily") (TyCon "Bool")))
(DFunDef false "isWasmExternFamily" ((PCon "WasmRefCell")) (EVar "False"))
(DFunDef false "isWasmExternFamily" ((PCon "WasmConstant")) (EVar "False"))
(DFunDef false "isWasmExternFamily" ((PCon "WasmFallthrough")) (EVar "False"))
(DFunDef false "isWasmExternFamily" (PWild) (EVar "True"))
(DTypeSig true "wasmUses" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "WasmUse"))))
(DFunDef false "wasmUses" ((PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "wasmUseIndex")) (arm (PCon "Some" (PVar "us")) () (EVar "us")) (arm (PCon "None") () (EListLit))))
(DTypeSig true "wasmHostKeys" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wasmHostKeys" ((PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "wasmHostKeyIndex")) (arm (PCon "Some" (PVar "ks")) () (EVar "ks")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "catalogIndex" (TyApp (TyCon "OrdMap") (TyCon "ExternRow")))
(DFunDef false "catalogIndex" () (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "rowName") (EVar "r")) (EVar "r")))) (EVar "catalogRows"))) (EVar "omEmpty")))
(DTypeSig false "wasmUseIndex" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "WasmUse"))))
(DFunDef false "wasmUseIndex" () (EApp (EApp (EVar "omFromPairs") (EVar "wasmUseRows")) (EVar "omEmpty")))
(DTypeSig false "wasmHostKeyIndex" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wasmHostKeyIndex" () (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "flatMap") (EVar "rowHostKeyPair")) (EVar "catalogRows"))) (EVar "omEmpty")))
(DTypeSig false "rowHostKeyPair" (TyFun (TyCon "ExternRow") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "rowHostKeyPair" ((PVar "r")) (EBlock (DoLet false false (PVar "helperKeys") (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "rowName") (EVar "r"))) (EVar "wasmHelperKeyIndex")) (arm (PCon "Some" (PVar "ks")) () (EVar "ks")) (arm (PCon "None") () (EListLit)))) (DoExpr (EMatch (EBinOp "++" (EApp (EVar "envImportKeys") (EApp (EVar "rowWasm") (EVar "r"))) (EVar "helperKeys")) (arm (PList) () (EListLit)) (arm (PVar "ks") () (EListLit (ETuple (EApp (EVar "rowName") (EVar "r")) (EVar "ks"))))))))
(DTypeSig false "envImportKeys" (TyFun (TyApp (TyCon "Disposition") (TyCon "WasmFamily")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "envImportKeys" ((PCon "EnvImport" PWild (PVar "key"))) (EListLit (EVar "key")))
(DFunDef false "envImportKeys" (PWild) (EListLit))
(DTypeSig false "wasmHelperKeyIndex" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wasmHelperKeyIndex" () (EApp (EApp (EVar "omFromPairs") (EVar "wasmHelperKeyRows")) (EVar "omEmpty")))
(DTypeSig true "wasmHelperKeyRows" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wasmHelperKeyRows" () (EListLit (ETuple (ELit (LString "ePutStr")) (EListLit (ELit (LString "mdk_write_err_byte")))) (ETuple (ELit (LString "ePutStrLn")) (EListLit (ELit (LString "mdk_write_err_byte")))) (ETuple (ELit (LString "panic")) (EListLit (ELit (LString "mdk_write_err_byte")))) (ETuple (ELit (LString "indexError")) (EListLit (ELit (LString "mdk_write_err_byte")))) (ETuple (ELit (LString "panicAt")) (EListLit (ELit (LString "mdk_write_err_byte")))) (ETuple (ELit (LString "readFile")) (EBinOp "++" (EVar "grantChannelKeys") (EVar "readChannelKeys"))) (ETuple (ELit (LString "readFileBytes")) (EBinOp "++" (EVar "grantChannelKeys") (EVar "readChannelKeys"))) (ETuple (ELit (LString "fetchText")) (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte")))) (ETuple (ELit (LString "writeFileBytes")) (EBinOp "++" (EVar "grantChannelKeys") (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (ELit (LString "mdk_write_file_reset")) (ELit (LString "mdk_write_file_push")) (ELit (LString "mdk_write_file_commit")) (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte"))))) (ETuple (ELit (LString "writeFile")) (EBinOp "++" (EApp (EVar "fileOpKeys") (ELit (LString "mdk_write_file"))) (EListLit (ELit (LString "mdk_write_file_reset")) (ELit (LString "mdk_write_file_push"))))) (ETuple (ELit (LString "appendFile")) (EBinOp "++" (EApp (EVar "fileOpKeys") (ELit (LString "mdk_append_file"))) (EListLit (ELit (LString "mdk_write_file_reset")) (ELit (LString "mdk_write_file_push"))))) (ETuple (ELit (LString "writeFileMode")) (EBinOp "++" (EApp (EVar "fileOpKeys") (ELit (LString "mdk_write_file_mode"))) (EListLit (ELit (LString "mdk_write_file_reset")) (ELit (LString "mdk_write_file_push"))))) (ETuple (ELit (LString "rename")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_rename")))) (ETuple (ELit (LString "makeDir")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_make_dir")))) (ETuple (ELit (LString "removeFile")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_remove_file")))) (ETuple (ELit (LString "removeDir")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_remove_dir")))) (ETuple (ELit (LString "fsync")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_fsync")))) (ETuple (ELit (LString "fileMode")) (EBinOp "++" (EApp (EVar "fileOpKeys") (ELit (LString "mdk_file_mode"))) (EListLit (ELit (LString "mdk_stat_field"))))) (ETuple (ELit (LString "listDir")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_list_dir")))) (ETuple (ELit (LString "statFile")) (EBinOp "++" (EApp (EVar "fileOpKeys") (ELit (LString "mdk_stat_file"))) (EListLit (ELit (LString "mdk_stat_field"))))) (ETuple (ELit (LString "fileExists")) (EBinOp "++" (EBinOp "++" (EVar "grantChannelKeys") (EVar "refusalPanicKeys")) (EListLit (ELit (LString "mdk_file_exists"))))) (ETuple (ELit (LString "canonicalizePath")) (EBinOp "++" (EBinOp "++" (EVar "grantChannelKeys") (EVar "refusalPanicKeys")) (EListLit (ELit (LString "mdk_canonicalize_path"))))) (ETuple (ELit (LString "getEnv")) (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (ELit (LString "mdk_get_env")) (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte")))) (ETuple (ELit (LString "args")) (EListLit (ELit (LString "mdk_args_count")) (ELit (LString "mdk_arg_len")) (ELit (LString "mdk_arg_byte")))) (ETuple (ELit (LString "readLine")) (EApp (EVar "hostResultKeys") (ELit (LString "mdk_read_line")))) (ETuple (ELit (LString "readLineOpt")) (EApp (EVar "hostResultKeys") (ELit (LString "mdk_read_line")))) (ETuple (ELit (LString "readAll")) (EApp (EVar "hostResultKeys") (ELit (LString "mdk_read_all")))) (ETuple (ELit (LString "readExactly")) (EApp (EVar "hostResultKeys") (ELit (LString "mdk_read_exactly")))) (ETuple (ELit (LString "osEntropyBytes")) (EBinOp "::" (ELit (LString "mdk_os_entropy")) (EVar "refusedPanicKeys"))) (ETuple (ELit (LString "executablePath")) (EApp (EVar "hostResultKeys") (ELit (LString "mdk_executable_path")))) (ETuple (ELit (LString "stringToFloat")) (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (ELit (LString "mdk_str_to_float")) (ELit (LString "mdk_str_to_float_ok"))))))
(DTypeSig false "grantChannelKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "grantChannelKeys" () (EListLit (ELit (LString "mdk_grant_reset")) (ELit (LString "mdk_grant_push"))))
(DTypeSig false "fileOpKeys" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fileOpKeys" ((PVar "key")) (EBinOp "++" (EVar "grantChannelKeys") (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (EVar "key") (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte")))))
(DTypeSig false "refusalPanicKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "refusalPanicKeys" () (EBinOp "++" (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push"))) (EVar "refusedPanicKeys")))
(DTypeSig false "refusedPanicKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "refusedPanicKeys" () (EListLit (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte")) (ELit (LString "mdk_write_err_byte"))))
(DTypeSig true "fileBoundHostKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "fileBoundHostKeys" () (EBinOp "++" (EVar "grantChannelKeys") (EListLit (ELit (LString "mdk_file_bound_enter")) (ELit (LString "mdk_file_bound_exit")))))
(DTypeSig false "hostResultKeys" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "hostResultKeys" ((PVar "key")) (EListLit (EVar "key") (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte"))))
(DTypeSig false "readChannelKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "readChannelKeys" () (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (ELit (LString "mdk_read_file")) (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte"))))
(DTypeSig true "wasmTupleArities" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "wasmTupleArities" ((PLit (LString "statFile"))) (EListLit (ELit (LInt 4))))
(DFunDef false "wasmTupleArities" (PWild) (EListLit))
(DTypeSig true "wasmUseRows" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "WasmUse")))))
(DFunDef false "wasmUseRows" () (EListLit (ETuple (ELit (LString "ePutStr")) (EListLit (EVar "UseEPut"))) (ETuple (ELit (LString "ePutStrLn")) (EListLit (EVar "UseEPut"))) (ETuple (ELit (LString "readFile")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "readFileBytes")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseArray") (EVar "UseFileBytes"))) (ETuple (ELit (LString "writeFile")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "appendFile")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "writeFileMode")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "writeFileBytes")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseArray") (EVar "UseFileBytes"))) (ETuple (ELit (LString "rename")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "makeDir")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "removeFile")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "removeDir")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "fsync")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "fileMode")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "listDir")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "statFile")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseFloat"))) (ETuple (ELit (LString "fileExists")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "canonicalizePath")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "args")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseArgs"))) (ETuple (ELit (LString "getEnv")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "readLine")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "readLineOpt")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "readAll")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "readExactly")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "osEntropyBytes")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseArray"))) (ETuple (ELit (LString "executablePath")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "panic")) (EListLit (EVar "UseStr") (EVar "UseEPut"))) (ETuple (ELit (LString "indexError")) (EListLit (EVar "UseStr") (EVar "UseEPut"))) (ETuple (ELit (LString "panicAt")) (EListLit (EVar "UseStr") (EVar "UseEPut"))) (ETuple (ELit (LString "wallTimeSec")) (EListLit (EVar "UseFloat") (EVar "UseClock"))) (ETuple (ELit (LString "monotonicSec")) (EListLit (EVar "UseFloat") (EVar "UseClock"))) (ETuple (ELit (LString "sleepMs")) (EListLit (EVar "UseClock"))) (ETuple (ELit (LString "fetchText")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "randomInt")) (EListLit (EVar "UseRng"))) (ETuple (ELit (LString "randomBool")) (EListLit (EVar "UseRng"))) (ETuple (ELit (LString "randomFloat")) (EListLit (EVar "UseRng") (EVar "UseFloat") (EVar "UseFloatRng"))) (ETuple (ELit (LString "randomChar")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseRng"))) (ETuple (ELit (LString "setSeed")) (EListLit (EVar "UseRng"))) (ETuple (ELit (LString "randomState")) (EListLit (EVar "UseRng") (EVar "UseU64"))) (ETuple (ELit (LString "restoreRandomState")) (EListLit (EVar "UseRng") (EVar "UseU64"))) (ETuple (ELit (LString "hashInt")) (EListLit (EVar "UseHash"))) (ETuple (ELit (LString "hashFloat")) (EListLit (EVar "UseHash") (EVar "UseFloat") (EVar "UseFloatHash"))) (ETuple (ELit (LString "hashString")) (EListLit (EVar "UseHash"))) (ETuple (ELit (LString "hashChar")) (EListLit (EVar "UseHash"))) (ETuple (ELit (LString "hashBool")) (EListLit (EVar "UseHash"))) (ETuple (ELit (LString "intToFloat")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "floatToInt")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "floatRem")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "sqrt")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "cbrt")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "exp")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "log")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "log2")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "log10")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "sin")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "cos")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "tan")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "asin")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "acos")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "atan")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "sinh")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "cosh")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "tanh")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "floor")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "ceil")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "round")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "trunc")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "pow")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "atan2")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "hypot")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "intBitsToFloat")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "bytesToFloat64")) (EListLit (EVar "UseFloat") (EVar "UseArray"))) (ETuple (ELit (LString "floatToBytes64")) (EListLit (EVar "UseFloat") (EVar "UseArray"))) (ETuple (ELit (LString "floatToString")) (EListLit (EVar "UseStr") (EVar "UseFloat"))) (ETuple (ELit (LString "debugStringLit")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf"))) (ETuple (ELit (LString "debugCharLit")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf"))) (ETuple (ELit (LString "arrayLength")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayMake")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayMakeWith")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayGetUnsafe")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arraySetUnsafe")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayCopy")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayBlit")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayFill")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayFromList")) (EListLit (EVar "UseArray") (EVar "UseList"))) (ETuple (ELit (LString "u64Truncate")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64TruncateToInt")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64BitAnd")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64BitOr")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64BitXor")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64ShiftLeft")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64ShiftRight")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64MulHigh")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "i64FromBits")) (EListLit (EVar "UseU64") (EVar "UseI64"))) (ETuple (ELit (LString "i64ToBits")) (EListLit (EVar "UseU64") (EVar "UseI64"))) (ETuple (ELit (LString "byteBlockMake")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockLength")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockGetUnsafe")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockSetUnsafe")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockCopyUnsafe")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockBlit")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockFromIntArray")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockToIntArray")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockFromString")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockToString")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockWriteStdout")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "stringToChars")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrCodec") (EVar "UseArray"))) (ETuple (ELit (LString "stringFromChars")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrCodec") (EVar "UseArray"))) (ETuple (ELit (LString "stringToUtf8Bytes")) (EListLit (EVar "UseStr") (EVar "UseStrCodec") (EVar "UseArray"))) (ETuple (ELit (LString "stringFromUtf8Bytes")) (EListLit (EVar "UseStr") (EVar "UseStrCodec") (EVar "UseArray"))) (ETuple (ELit (LString "charToStr")) (EListLit (EVar "UseStrLeaf"))) (ETuple (ELit (LString "charFromCode")) (EListLit (EVar "UseCharFromCode"))) (ETuple (ELit (LString "stringSlice")) (EListLit (EVar "UseStrLeaf"))) (ETuple (ELit (LString "stringConcat")) (EListLit (EVar "UseStrLeaf"))) (ETuple (ELit (LString "stringIndexOf")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrSearch"))) (ETuple (ELit (LString "stringStartsWith")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf"))) (ETuple (ELit (LString "stringEndsWith")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf"))) (ETuple (ELit (LString "stringCountOccurrences")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrSearch"))) (ETuple (ELit (LString "stringLastIndexOf")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrSearch"))) (ETuple (ELit (LString "stringToInt")) (EListLit (EVar "UseStr") (EVar "UseStrToInt"))) (ETuple (ELit (LString "stringReverse")) (EListLit (EVar "UseStr") (EVar "UseStrReverse"))) (ETuple (ELit (LString "stringJoin")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseStrJoin"))) (ETuple (ELit (LString "stringCompare")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrSearch"))) (ETuple (ELit (LString "stringToFloat")) (EListLit (EVar "UseStr") (EVar "UseFloat") (EVar "UseFloatStr"))) (ETuple (ELit (LString "charIsAlpha")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charIsSpace")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charIsUpper")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charIsLower")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charIsPunct")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charToUpper")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charToLower")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "stringToUpper")) (EListLit (EVar "UseStrLeaf"))) (ETuple (ELit (LString "stringToLower")) (EListLit (EVar "UseStrLeaf")))))
(DTypeSig false "interpLlvmOnly" (TyCon "String"))
(DFunDef false "interpLlvmOnly" () (ELit (LString "implemented by llvm, missing from the interpreter")))
(DTypeSig false "wasmNoSockets" (TyCon "String"))
(DFunDef false "wasmNoSockets" () (ELit (LString "the `net` module is native-only: raw BSD sockets have no WasmGC equivalent — build for a native target instead")))
(DTypeSig false "noHttpClient" (TyCon "String"))
(DFunDef false "noHttpClient" () (ELit (LString "`fetchText` is lowered only by the wasmgc/edge target: native has no HTTP client and no TLS — build for `wasmgc/edge`")))
(DTypeSig false "interpNoHttpClient" (TyCon "String"))
(DFunDef false "interpNoHttpClient" () (ELit (LString "the interpreter has no HTTP client; only the wasmgc/edge target lowers `fetchText`")))
(DTypeSig true "catalogRows" (TyApp (TyCon "List") (TyCon "ExternRow")))
(DFunDef false "catalogRows" () (EListLit (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "putStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_putstr")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "putStrLn"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_putstrln")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ePutStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_eputstr")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ePutStrLn"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_eputstrln")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "flushStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_flushstdout")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readLine"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_line")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readLineOpt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_line_opt")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readAll"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_all")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readExactly"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_exactly")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "Ref"))) (EApp (EVar "Inline") (EVar "LlvmRefCell"))) (EApp (EVar "Inline") (EVar "WasmRefCell"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "setRef"))) (EApp (EVar "Inline") (EVar "LlvmRefCell"))) (EApp (EVar "Inline") (EVar "WasmRefCell"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readFileBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_file_bytes")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFileBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file_bytes")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFileMode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file_mode")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "appendFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_append_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fileExists"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_file_exists")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fileMode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_file_mode")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "canonicalizePath"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_canonicalize_path")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "listDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_list_dir")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "makeDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_make_dir")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "removeFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_remove_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "rename"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_rename")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fsync"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_fsync")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "removeDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_remove_dir")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "statFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_stat_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "args"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmEnv")) (ELit (LString "mdk_args")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "getEnv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmEnv")) (ELit (LString "mdk_get_env")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "executablePath"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_executable_path")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildFingerprint"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_fingerprint")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "build-provenance (the staleness guard) is meaningless in the WasmGC playground — there is no build-provenance object linked in and no host filesystem to re-hash compiler/ against; the compiler is only ever built via the LLVM backend, never wasm")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildCommit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_commit")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "same rationale as buildFingerprint (a sibling provenance stamp) — no build-provenance object linked in and no host git checkout in the WasmGC playground")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildDate"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_date")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "same rationale as buildFingerprint (a sibling provenance stamp) — no build-provenance object linked into the WasmGC playground")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "runCommand"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_run_command")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "a subprocess has no WasmGC host equivalent: Exec is granted on native and run only, and no wasm profile grants it")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "implemented by llvm, missing from the interpreter on purpose: the interpreter waits on a decision about the --allow-exec security posture")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "runCommandBatch"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_run_command_batch")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "a subprocess has no WasmGC host equivalent: Exec is granted on native and run only, and no wasm profile grants it")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "implemented by llvm, missing from the interpreter on purpose: the same --allow-exec posture as runCommand")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "exit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_exit")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_exit")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "panic"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_panic")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexError"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_msg")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexErrorAt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_at")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexErrorAtSite"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_at")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "panicAt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_panic")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sliceError"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_slice_oob")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stashRunStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_stash_run_stdout")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "internal `medaka run` CLI plumbing (interpreter-only outputRef stash for the \"run drops stdout on panic\" fix) — the compiler is only ever built via the LLVM backend, never wasm, so no WasmGC program ever exercises this")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "enableRunStdoutFlush"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_enable_run_stdout_flush")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "internal `medaka run` CLI plumbing (arms the abort-time flush for the \"run drops stdout on panic\" fix) — the compiler is only ever built via the LLVM backend, never wasm, so no WasmGC program ever exercises this")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "__fallthrough__"))) (EApp (EVar "Inline") (EVar "LlvmFallthrough"))) (EApp (EVar "Inline") (EVar "WasmFallthrough"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "assertSnapshot"))) (EApp (EApp (EVar "NotProvided") (EVar "GapTodo")) (ELit (LString "unimplemented in all 3 engines, no stdlib caller — forward-declared snapshot-testing primitive, not an asymmetric regression")))) (EApp (EApp (EVar "NotProvided") (EVar "GapTodo")) (ELit (LString "unimplemented in all 3 engines, no stdlib caller — forward-declared snapshot-testing primitive, not an asymmetric regression")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "unimplemented in all 3 engines (see llvm/wasm TODO rows); no stdlib caller yet — a forward-declared snapshot-testing primitive (TESTING-DESIGN.md §4.7 \"medaka test --promote\"); recorded as a bug row for the interpreter although it is not an asymmetric regression against another engine")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netResolve"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_resolve")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpConnect"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_connect")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpListen"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_listen")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netListenPort"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_listen_port")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpAccept"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_accept")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSend"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSendFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netRecv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_recv")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netShutdown"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_shutdown")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netClose"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_close")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netCloseListener"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_close")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetTimeout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_timeout")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "socketFd"))) (EApp (EVar "Inline") (EVar "LlvmNet"))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "listenSocketFd"))) (EApp (EVar "Inline") (EVar "LlvmNet"))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pdsSignalStart"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_pds_signal_start")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "POSIX SIGTERM self-pipe and fd readiness are native-only; wasm_emit rejects the net family")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "the interpreter has no signal host binding yet, though the run profile grants Signal (TARGETS-DESIGN §8.1)")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pdsSignalRequested"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_pds_signal_requested")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "POSIX SIGTERM state is native-only; wasm_emit rejects the net family")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "the interpreter has no signal host binding yet, though the run profile grants Signal (TARGETS-DESIGN §8.1)")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ioPoll"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_io_poll")))) (EApp (EApp (EVar "TrapStub") (EVar "WasmLeaf")) (ELit (LString "bound to a coded runtime trap, not a value: E-WASM-NO-BINDING after evaluating its arguments; the Net/Stdin readiness bindings are #3666")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetNonblock"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_nonblock")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetNonblockListener"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_nonblock")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryAccept"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_accept")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netConnectStart"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_connect_start")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netConnectCheck"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_connect_check")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryRecv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_recv")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryRecvBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_recv_bytes")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySend"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySendFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSendBytesFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send_bytes_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySendBytesFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send_bytes_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "wallTimeSec"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_wall_time_sec")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_wall_time_sec")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "monotonicSec"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_monotonic_sec")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_monotonic_sec")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sleepMs"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_sleep_ms")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sleep_ms")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fetchText"))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "noHttpClient"))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_fetch_text")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "interpNoHttpClient"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "allocBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_alloc_bytes")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "real GC-byte-counter FFI in llvm, no wasm host-import wired")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomInt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_int")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomBool"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_bool")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomChar"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_char")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "setSeed"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_set_seed")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomState"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_state")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "restoreRandomState"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_restore_random_state")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "osEntropyBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_os_entropy_bytes")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashInt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_int")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashChar"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_char")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashBool"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_bool")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pi"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "e"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intMinBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intMaxBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charMinBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charMaxBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intToFloat"))) (EApp (EVar "Inline") (EVar "LlvmNum"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToInt"))) (EApp (EVar "Inline") (EVar "LlvmNum"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatRem"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_rem")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitAnd"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_and")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitOr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_or")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitXor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_xor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "shiftLeft"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_left")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "shiftRight"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_right")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitNot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_not")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sqrt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sqrt")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cbrt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cbrt")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cbrt")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "exp"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_exp")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_exp")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log2"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log2")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log2")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log10"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log10")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log10")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sin"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sin")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sin")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cos"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cos")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cos")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "tan"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_tan")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_tan")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "asin"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_asin")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_asin")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "acos"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_acos")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_acos")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "atan"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_atan")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_atan")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sinh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sinh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sinh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cosh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cosh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cosh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "tanh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_tanh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_tanh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_floor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ceil"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_ceil")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "round"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_round")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "trunc"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_trunc")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pow"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_pow")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_pow")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "atan2"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_atan2")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_atan2")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hypot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_hypot")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_hypot")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitsToFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_int_bits_to_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bytesToFloat64"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_bytes_to_float64")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToBytes64"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_to_bytes64")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_int_to_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_to_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "debugStringLit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmDebugLit")) (ELit (LString "mdk_debug_string_lit")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "debugCharLit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmDebugLit")) (ELit (LString "mdk_debug_char_lit")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayLength"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayMake"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_make")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayMakeWith"))) (EApp (EVar "Inline") (EVar "LlvmArrayMakeWith"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayGetUnsafe"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arraySetUnsafe"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayCopy"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_copy")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayBlit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_blit")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayFill"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_fill")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayFromList"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_from_list")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u8Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u8ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u16Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u16ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u32Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u32ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitAnd"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_and")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitOr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_or")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitXor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_xor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitNot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_not")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intShiftLeft"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_left")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intShiftRight"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_right")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64Truncate"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64TruncateToInt"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitAnd"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitOr"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitXor"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64ShiftLeft"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64ShiftRight"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64MulHigh"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i32Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i32ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i64FromBits"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i64ToBits"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockMake"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_make")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockLength"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_length")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockGetUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_get")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockSetUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_set")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockCopyUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_copy")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockBlit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_blit")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockFromIntArray"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_from_int_array")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockToIntArray"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_to_int_array")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockFromString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_from_string")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_to_string")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockWriteStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_byteblock_write_stdout")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToChars"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_to_chars")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringFromChars"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_from_chars")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToUtf8Bytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_to_utf8_bytes")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringFromUtf8Bytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_from_utf8_bytes")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmChar")) (ELit (LString "mdk_char_to_str")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charCode"))) (EApp (EVar "Inline") (EVar "LlvmChar"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charFromCode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_char_from_code")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringLength"))) (EApp (EVar "Inline") (EVar "LlvmStr"))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringByteLength"))) (EApp (EVar "Inline") (EVar "LlvmStr"))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringSlice"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_slice")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringConcat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_concat")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringIndexOf"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_index_of")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringStartsWith"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_starts_with")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringEndsWith"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_ends_with")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringCountOccurrences"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_count_occurrences")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringLastIndexOf"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_last_index_of")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToInt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_to_int")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringReverse"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_reverse")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringJoin"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_join")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringCompare"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_compare")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_to_float")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsAlpha"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_alpha")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsSpace"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_space")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_upper")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_lower")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsPunct"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_punct")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_to_upper")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_to_lower")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_string_to_upper")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_string_to_lower")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "ExternDecl" false))))
(DData Public "RuntimeExternDomain" () ((variant "LoadedRuntimeExterns" (ConPos (TyApp (TyCon "List") (TyCon "ExternDecl")))) (variant "PreludeFreeRuntime" (ConPos))) ())
(DTypeSig true "runtimeDomain" (TyFun (TyApp (TyCon "List") (TyCon "ExternDecl")) (TyCon "RuntimeExternDomain")))
(DFunDef false "runtimeDomain" () (EVar "LoadedRuntimeExterns"))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omLookup" false))))
(DData Public "GapKind" () ((variant "GapBug" (ConPos)) (variant "GapDead" (ConPos)) (variant "GapTodo" (ConPos)) (variant "GapPermanent" (ConPos)) (variant "GapUnported" (ConPos))) ())
(DData Public "Disposition" ("f") ((variant "CSymbol" (ConPos (TyVar "f") (TyCon "String"))) (variant "EnvImport" (ConPos (TyVar "f") (TyCon "String"))) (variant "Inline" (ConPos (TyVar "f"))) (variant "Interpreted" (ConPos)) (variant "TrapStub" (ConPos (TyVar "f") (TyCon "String"))) (variant "FrozenConstant" (ConPos (TyVar "f") (TyCon "String"))) (variant "NotProvided" (ConPos (TyCon "GapKind") (TyCon "String")))) ())
(DData Public "LlvmFamily" () ((variant "LlvmStr" (ConPos)) (variant "LlvmNum" (ConPos)) (variant "LlvmIo" (ConPos)) (variant "LlvmAbort" (ConPos)) (variant "LlvmArrIntrinsic" (ConPos)) (variant "LlvmArrLeaf" (ConPos)) (variant "LlvmByteBlock" (ConPos)) (variant "LlvmChar" (ConPos)) (variant "LlvmStrChar" (ConPos)) (variant "LlvmUnicode" (ConPos)) (variant "LlvmAdt" (ConPos)) (variant "LlvmEnv" (ConPos)) (variant "LlvmFile" (ConPos)) (variant "LlvmNet" (ConPos)) (variant "LlvmRng" (ConPos)) (variant "LlvmHash" (ConPos)) (variant "LlvmBit" (ConPos)) (variant "LlvmFixedWidth" (ConPos)) (variant "LlvmU64" (ConPos)) (variant "LlvmDebugLit" (ConPos)) (variant "LlvmPerf" (ConPos)) (variant "LlvmArrayMakeWith" (ConPos)) (variant "LlvmRefCell" (ConPos)) (variant "LlvmConstant" (ConPos)) (variant "LlvmFallthrough" (ConPos))) ())
(DData Public "WasmFamily" () ((variant "WasmStr" (ConPos)) (variant "WasmLeaf" (ConPos)) (variant "WasmArray" (ConPos)) (variant "WasmByteBlock" (ConPos)) (variant "WasmRefCell" (ConPos)) (variant "WasmConstant" (ConPos)) (variant "WasmFallthrough" (ConPos))) ())
(DData Public "WasmUse" () ((variant "UseStr" (ConPos)) (variant "UseStrLeaf" (ConPos)) (variant "UseRng" (ConPos)) (variant "UseHash" (ConPos)) (variant "UseFloat" (ConPos)) (variant "UseU64" (ConPos)) (variant "UseI64" (ConPos)) (variant "UseMath" (ConPos)) (variant "UseFloatStr" (ConPos)) (variant "UseFloatHash" (ConPos)) (variant "UseFloatRng" (ConPos)) (variant "UseStrSearch" (ConPos)) (variant "UseStrCodec" (ConPos)) (variant "UseArray" (ConPos)) (variant "UseList" (ConPos)) (variant "UseCharFromCode" (ConPos)) (variant "UseCharClass" (ConPos)) (variant "UseEPut" (ConPos)) (variant "UseByteBlock" (ConPos)) (variant "UseArgs" (ConPos)) (variant "UseFileBytes" (ConPos)) (variant "UseClock" (ConPos)) (variant "UseStrToInt" (ConPos)) (variant "UseStrReverse" (ConPos)) (variant "UseStrJoin" (ConPos))) ())
(DImpl true "Eq" ((TyCon "WasmUse")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "UseStr") (PCon "UseStr")) () (EVar "True")) (arm (PTuple (PCon "UseStrLeaf") (PCon "UseStrLeaf")) () (EVar "True")) (arm (PTuple (PCon "UseRng") (PCon "UseRng")) () (EVar "True")) (arm (PTuple (PCon "UseHash") (PCon "UseHash")) () (EVar "True")) (arm (PTuple (PCon "UseFloat") (PCon "UseFloat")) () (EVar "True")) (arm (PTuple (PCon "UseU64") (PCon "UseU64")) () (EVar "True")) (arm (PTuple (PCon "UseI64") (PCon "UseI64")) () (EVar "True")) (arm (PTuple (PCon "UseMath") (PCon "UseMath")) () (EVar "True")) (arm (PTuple (PCon "UseFloatStr") (PCon "UseFloatStr")) () (EVar "True")) (arm (PTuple (PCon "UseFloatHash") (PCon "UseFloatHash")) () (EVar "True")) (arm (PTuple (PCon "UseFloatRng") (PCon "UseFloatRng")) () (EVar "True")) (arm (PTuple (PCon "UseStrSearch") (PCon "UseStrSearch")) () (EVar "True")) (arm (PTuple (PCon "UseStrCodec") (PCon "UseStrCodec")) () (EVar "True")) (arm (PTuple (PCon "UseArray") (PCon "UseArray")) () (EVar "True")) (arm (PTuple (PCon "UseList") (PCon "UseList")) () (EVar "True")) (arm (PTuple (PCon "UseCharFromCode") (PCon "UseCharFromCode")) () (EVar "True")) (arm (PTuple (PCon "UseCharClass") (PCon "UseCharClass")) () (EVar "True")) (arm (PTuple (PCon "UseEPut") (PCon "UseEPut")) () (EVar "True")) (arm (PTuple (PCon "UseByteBlock") (PCon "UseByteBlock")) () (EVar "True")) (arm (PTuple (PCon "UseArgs") (PCon "UseArgs")) () (EVar "True")) (arm (PTuple (PCon "UseFileBytes") (PCon "UseFileBytes")) () (EVar "True")) (arm (PTuple (PCon "UseClock") (PCon "UseClock")) () (EVar "True")) (arm (PTuple (PCon "UseStrToInt") (PCon "UseStrToInt")) () (EVar "True")) (arm (PTuple (PCon "UseStrReverse") (PCon "UseStrReverse")) () (EVar "True")) (arm (PTuple (PCon "UseStrJoin") (PCon "UseStrJoin")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "WasmUse")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "UseStr") () (ELit (LString "UseStr"))) (arm (PCon "UseStrLeaf") () (ELit (LString "UseStrLeaf"))) (arm (PCon "UseRng") () (ELit (LString "UseRng"))) (arm (PCon "UseHash") () (ELit (LString "UseHash"))) (arm (PCon "UseFloat") () (ELit (LString "UseFloat"))) (arm (PCon "UseU64") () (ELit (LString "UseU64"))) (arm (PCon "UseI64") () (ELit (LString "UseI64"))) (arm (PCon "UseMath") () (ELit (LString "UseMath"))) (arm (PCon "UseFloatStr") () (ELit (LString "UseFloatStr"))) (arm (PCon "UseFloatHash") () (ELit (LString "UseFloatHash"))) (arm (PCon "UseFloatRng") () (ELit (LString "UseFloatRng"))) (arm (PCon "UseStrSearch") () (ELit (LString "UseStrSearch"))) (arm (PCon "UseStrCodec") () (ELit (LString "UseStrCodec"))) (arm (PCon "UseArray") () (ELit (LString "UseArray"))) (arm (PCon "UseList") () (ELit (LString "UseList"))) (arm (PCon "UseCharFromCode") () (ELit (LString "UseCharFromCode"))) (arm (PCon "UseCharClass") () (ELit (LString "UseCharClass"))) (arm (PCon "UseEPut") () (ELit (LString "UseEPut"))) (arm (PCon "UseByteBlock") () (ELit (LString "UseByteBlock"))) (arm (PCon "UseArgs") () (ELit (LString "UseArgs"))) (arm (PCon "UseFileBytes") () (ELit (LString "UseFileBytes"))) (arm (PCon "UseClock") () (ELit (LString "UseClock"))) (arm (PCon "UseStrToInt") () (ELit (LString "UseStrToInt"))) (arm (PCon "UseStrReverse") () (ELit (LString "UseStrReverse"))) (arm (PCon "UseStrJoin") () (ELit (LString "UseStrJoin")))))))
(DData Public "ExternRow" () ((variant "ExternRow" (ConPos (TyCon "String") (TyApp (TyCon "Disposition") (TyCon "LlvmFamily")) (TyApp (TyCon "Disposition") (TyCon "WasmFamily")) (TyApp (TyCon "Disposition") (TyCon "Unit"))))) ())
(DTypeSig true "rowName" (TyFun (TyCon "ExternRow") (TyCon "String")))
(DFunDef false "rowName" ((PCon "ExternRow" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig true "rowLlvm" (TyFun (TyCon "ExternRow") (TyApp (TyCon "Disposition") (TyCon "LlvmFamily"))))
(DFunDef false "rowLlvm" ((PCon "ExternRow" PWild (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig true "rowWasm" (TyFun (TyCon "ExternRow") (TyApp (TyCon "Disposition") (TyCon "WasmFamily"))))
(DFunDef false "rowWasm" ((PCon "ExternRow" PWild PWild (PVar "w") PWild)) (EVar "w"))
(DTypeSig true "rowEval" (TyFun (TyCon "ExternRow") (TyApp (TyCon "Disposition") (TyCon "Unit"))))
(DFunDef false "rowEval" ((PCon "ExternRow" PWild PWild PWild (PVar "v"))) (EVar "v"))
(DTypeSig true "dispositionFamily" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyApp (TyCon "Option") (TyVar "f"))))
(DFunDef false "dispositionFamily" ((PCon "CSymbol" (PVar "f") PWild)) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "dispositionFamily" ((PCon "EnvImport" (PVar "f") PWild)) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "dispositionFamily" ((PCon "Inline" (PVar "f"))) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "dispositionFamily" ((PCon "Interpreted")) (EVar "None"))
(DFunDef false "dispositionFamily" ((PCon "TrapStub" (PVar "f") PWild)) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "dispositionFamily" ((PCon "FrozenConstant" (PVar "f") PWild)) (EApp (EVar "Some") (EVar "f")))
(DFunDef false "dispositionFamily" ((PCon "NotProvided" PWild PWild)) (EVar "None"))
(DTypeSig true "isBound" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyCon "Bool")))
(DFunDef false "isBound" ((PCon "NotProvided" PWild PWild)) (EVar "False"))
(DFunDef false "isBound" (PWild) (EVar "True"))
(DTypeSig true "ledgerEntry" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "ledgerEntry" ((PCon "NotProvided" (PVar "k") (PVar "why"))) (EApp (EVar "Some") (ETuple (EApp (EVar "gapKindName") (EVar "k")) (EVar "why"))))
(DFunDef false "ledgerEntry" ((PCon "TrapStub" PWild (PVar "why"))) (EApp (EVar "Some") (ETuple (ELit (LString "TRAP-STUB")) (EVar "why"))))
(DFunDef false "ledgerEntry" ((PCon "FrozenConstant" PWild (PVar "why"))) (EApp (EVar "Some") (ETuple (ELit (LString "FROZEN-CONSTANT")) (EVar "why"))))
(DFunDef false "ledgerEntry" (PWild) (EVar "None"))
(DTypeSig true "gapKindName" (TyFun (TyCon "GapKind") (TyCon "String")))
(DFunDef false "gapKindName" ((PCon "GapBug")) (ELit (LString "BUG")))
(DFunDef false "gapKindName" ((PCon "GapDead")) (ELit (LString "DEAD")))
(DFunDef false "gapKindName" ((PCon "GapTodo")) (ELit (LString "TODO")))
(DFunDef false "gapKindName" ((PCon "GapPermanent")) (ELit (LString "PERMANENT")))
(DFunDef false "gapKindName" ((PCon "GapUnported")) (ELit (LString "WASM-GAP")))
(DTypeSig true "catalogRow" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "ExternRow"))))
(DFunDef false "catalogRow" ((PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "catalogIndex")))
(DTypeSig true "llvmFamily" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "LlvmFamily"))))
(DFunDef false "llvmFamily" ((PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "dispositionFamily") (EApp (EVar "rowLlvm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "isLlvmExternFamily" (TyFun (TyCon "LlvmFamily") (TyCon "Bool")))
(DFunDef false "isLlvmExternFamily" ((PCon "LlvmRefCell")) (EVar "False"))
(DFunDef false "isLlvmExternFamily" ((PCon "LlvmConstant")) (EVar "False"))
(DFunDef false "isLlvmExternFamily" ((PCon "LlvmFallthrough")) (EVar "False"))
(DFunDef false "isLlvmExternFamily" (PWild) (EVar "True"))
(DTypeSig true "wasmFamily" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "WasmFamily"))))
(DFunDef false "wasmFamily" ((PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "dispositionFamily") (EApp (EVar "rowWasm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "isWasmExternFamily" (TyFun (TyCon "WasmFamily") (TyCon "Bool")))
(DFunDef false "isWasmExternFamily" ((PCon "WasmRefCell")) (EVar "False"))
(DFunDef false "isWasmExternFamily" ((PCon "WasmConstant")) (EVar "False"))
(DFunDef false "isWasmExternFamily" ((PCon "WasmFallthrough")) (EVar "False"))
(DFunDef false "isWasmExternFamily" (PWild) (EVar "True"))
(DTypeSig true "wasmUses" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "WasmUse"))))
(DFunDef false "wasmUses" ((PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "wasmUseIndex")) (arm (PCon "Some" (PVar "us")) () (EVar "us")) (arm (PCon "None") () (EListLit))))
(DTypeSig true "wasmHostKeys" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wasmHostKeys" ((PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "wasmHostKeyIndex")) (arm (PCon "Some" (PVar "ks")) () (EVar "ks")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "catalogIndex" (TyApp (TyCon "OrdMap") (TyCon "ExternRow")))
(DFunDef false "catalogIndex" () (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "rowName") (EVar "r")) (EVar "r")))) (EVar "catalogRows"))) (EVar "omEmpty")))
(DTypeSig false "wasmUseIndex" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "WasmUse"))))
(DFunDef false "wasmUseIndex" () (EApp (EApp (EVar "omFromPairs") (EVar "wasmUseRows")) (EVar "omEmpty")))
(DTypeSig false "wasmHostKeyIndex" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wasmHostKeyIndex" () (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EDictApp "flatMap") (EVar "rowHostKeyPair")) (EVar "catalogRows"))) (EVar "omEmpty")))
(DTypeSig false "rowHostKeyPair" (TyFun (TyCon "ExternRow") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "rowHostKeyPair" ((PVar "r")) (EBlock (DoLet false false (PVar "helperKeys") (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "rowName") (EVar "r"))) (EVar "wasmHelperKeyIndex")) (arm (PCon "Some" (PVar "ks")) () (EVar "ks")) (arm (PCon "None") () (EListLit)))) (DoExpr (EMatch (EBinOp "++" (EApp (EVar "envImportKeys") (EApp (EVar "rowWasm") (EVar "r"))) (EVar "helperKeys")) (arm (PList) () (EListLit)) (arm (PVar "ks") () (EListLit (ETuple (EApp (EVar "rowName") (EVar "r")) (EVar "ks"))))))))
(DTypeSig false "envImportKeys" (TyFun (TyApp (TyCon "Disposition") (TyCon "WasmFamily")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "envImportKeys" ((PCon "EnvImport" PWild (PVar "key"))) (EListLit (EVar "key")))
(DFunDef false "envImportKeys" (PWild) (EListLit))
(DTypeSig false "wasmHelperKeyIndex" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wasmHelperKeyIndex" () (EApp (EApp (EVar "omFromPairs") (EVar "wasmHelperKeyRows")) (EVar "omEmpty")))
(DTypeSig true "wasmHelperKeyRows" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wasmHelperKeyRows" () (EListLit (ETuple (ELit (LString "ePutStr")) (EListLit (ELit (LString "mdk_write_err_byte")))) (ETuple (ELit (LString "ePutStrLn")) (EListLit (ELit (LString "mdk_write_err_byte")))) (ETuple (ELit (LString "panic")) (EListLit (ELit (LString "mdk_write_err_byte")))) (ETuple (ELit (LString "indexError")) (EListLit (ELit (LString "mdk_write_err_byte")))) (ETuple (ELit (LString "panicAt")) (EListLit (ELit (LString "mdk_write_err_byte")))) (ETuple (ELit (LString "readFile")) (EBinOp "++" (EVar "grantChannelKeys") (EVar "readChannelKeys"))) (ETuple (ELit (LString "readFileBytes")) (EBinOp "++" (EVar "grantChannelKeys") (EVar "readChannelKeys"))) (ETuple (ELit (LString "fetchText")) (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte")))) (ETuple (ELit (LString "writeFileBytes")) (EBinOp "++" (EVar "grantChannelKeys") (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (ELit (LString "mdk_write_file_reset")) (ELit (LString "mdk_write_file_push")) (ELit (LString "mdk_write_file_commit")) (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte"))))) (ETuple (ELit (LString "writeFile")) (EBinOp "++" (EApp (EVar "fileOpKeys") (ELit (LString "mdk_write_file"))) (EListLit (ELit (LString "mdk_write_file_reset")) (ELit (LString "mdk_write_file_push"))))) (ETuple (ELit (LString "appendFile")) (EBinOp "++" (EApp (EVar "fileOpKeys") (ELit (LString "mdk_append_file"))) (EListLit (ELit (LString "mdk_write_file_reset")) (ELit (LString "mdk_write_file_push"))))) (ETuple (ELit (LString "writeFileMode")) (EBinOp "++" (EApp (EVar "fileOpKeys") (ELit (LString "mdk_write_file_mode"))) (EListLit (ELit (LString "mdk_write_file_reset")) (ELit (LString "mdk_write_file_push"))))) (ETuple (ELit (LString "rename")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_rename")))) (ETuple (ELit (LString "makeDir")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_make_dir")))) (ETuple (ELit (LString "removeFile")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_remove_file")))) (ETuple (ELit (LString "removeDir")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_remove_dir")))) (ETuple (ELit (LString "fsync")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_fsync")))) (ETuple (ELit (LString "fileMode")) (EBinOp "++" (EApp (EVar "fileOpKeys") (ELit (LString "mdk_file_mode"))) (EListLit (ELit (LString "mdk_stat_field"))))) (ETuple (ELit (LString "listDir")) (EApp (EVar "fileOpKeys") (ELit (LString "mdk_list_dir")))) (ETuple (ELit (LString "statFile")) (EBinOp "++" (EApp (EVar "fileOpKeys") (ELit (LString "mdk_stat_file"))) (EListLit (ELit (LString "mdk_stat_field"))))) (ETuple (ELit (LString "fileExists")) (EBinOp "++" (EBinOp "++" (EVar "grantChannelKeys") (EVar "refusalPanicKeys")) (EListLit (ELit (LString "mdk_file_exists"))))) (ETuple (ELit (LString "canonicalizePath")) (EBinOp "++" (EBinOp "++" (EVar "grantChannelKeys") (EVar "refusalPanicKeys")) (EListLit (ELit (LString "mdk_canonicalize_path"))))) (ETuple (ELit (LString "getEnv")) (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (ELit (LString "mdk_get_env")) (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte")))) (ETuple (ELit (LString "args")) (EListLit (ELit (LString "mdk_args_count")) (ELit (LString "mdk_arg_len")) (ELit (LString "mdk_arg_byte")))) (ETuple (ELit (LString "readLine")) (EApp (EVar "hostResultKeys") (ELit (LString "mdk_read_line")))) (ETuple (ELit (LString "readLineOpt")) (EApp (EVar "hostResultKeys") (ELit (LString "mdk_read_line")))) (ETuple (ELit (LString "readAll")) (EApp (EVar "hostResultKeys") (ELit (LString "mdk_read_all")))) (ETuple (ELit (LString "readExactly")) (EApp (EVar "hostResultKeys") (ELit (LString "mdk_read_exactly")))) (ETuple (ELit (LString "osEntropyBytes")) (EBinOp "::" (ELit (LString "mdk_os_entropy")) (EVar "refusedPanicKeys"))) (ETuple (ELit (LString "executablePath")) (EApp (EVar "hostResultKeys") (ELit (LString "mdk_executable_path")))) (ETuple (ELit (LString "stringToFloat")) (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (ELit (LString "mdk_str_to_float")) (ELit (LString "mdk_str_to_float_ok"))))))
(DTypeSig false "grantChannelKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "grantChannelKeys" () (EListLit (ELit (LString "mdk_grant_reset")) (ELit (LString "mdk_grant_push"))))
(DTypeSig false "fileOpKeys" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fileOpKeys" ((PVar "key")) (EBinOp "++" (EVar "grantChannelKeys") (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (EVar "key") (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte")))))
(DTypeSig false "refusalPanicKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "refusalPanicKeys" () (EBinOp "++" (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push"))) (EVar "refusedPanicKeys")))
(DTypeSig false "refusedPanicKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "refusedPanicKeys" () (EListLit (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte")) (ELit (LString "mdk_write_err_byte"))))
(DTypeSig true "fileBoundHostKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "fileBoundHostKeys" () (EBinOp "++" (EVar "grantChannelKeys") (EListLit (ELit (LString "mdk_file_bound_enter")) (ELit (LString "mdk_file_bound_exit")))))
(DTypeSig false "hostResultKeys" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "hostResultKeys" ((PVar "key")) (EListLit (EVar "key") (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte"))))
(DTypeSig false "readChannelKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "readChannelKeys" () (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push")) (ELit (LString "mdk_read_file")) (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte"))))
(DTypeSig true "wasmTupleArities" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "wasmTupleArities" ((PLit (LString "statFile"))) (EListLit (ELit (LInt 4))))
(DFunDef false "wasmTupleArities" (PWild) (EListLit))
(DTypeSig true "wasmUseRows" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "WasmUse")))))
(DFunDef false "wasmUseRows" () (EListLit (ETuple (ELit (LString "ePutStr")) (EListLit (EVar "UseEPut"))) (ETuple (ELit (LString "ePutStrLn")) (EListLit (EVar "UseEPut"))) (ETuple (ELit (LString "readFile")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "readFileBytes")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseArray") (EVar "UseFileBytes"))) (ETuple (ELit (LString "writeFile")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "appendFile")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "writeFileMode")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "writeFileBytes")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseArray") (EVar "UseFileBytes"))) (ETuple (ELit (LString "rename")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "makeDir")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "removeFile")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "removeDir")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "fsync")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "fileMode")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "listDir")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "statFile")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseFloat"))) (ETuple (ELit (LString "fileExists")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "canonicalizePath")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "args")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseArgs"))) (ETuple (ELit (LString "getEnv")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "readLine")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "readLineOpt")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "readAll")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "readExactly")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "osEntropyBytes")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseArray"))) (ETuple (ELit (LString "executablePath")) (EListLit (EVar "UseStr"))) (ETuple (ELit (LString "panic")) (EListLit (EVar "UseStr") (EVar "UseEPut"))) (ETuple (ELit (LString "indexError")) (EListLit (EVar "UseStr") (EVar "UseEPut"))) (ETuple (ELit (LString "panicAt")) (EListLit (EVar "UseStr") (EVar "UseEPut"))) (ETuple (ELit (LString "wallTimeSec")) (EListLit (EVar "UseFloat") (EVar "UseClock"))) (ETuple (ELit (LString "monotonicSec")) (EListLit (EVar "UseFloat") (EVar "UseClock"))) (ETuple (ELit (LString "sleepMs")) (EListLit (EVar "UseClock"))) (ETuple (ELit (LString "fetchText")) (EListLit (EVar "UseStr") (EVar "UseList"))) (ETuple (ELit (LString "randomInt")) (EListLit (EVar "UseRng"))) (ETuple (ELit (LString "randomBool")) (EListLit (EVar "UseRng"))) (ETuple (ELit (LString "randomFloat")) (EListLit (EVar "UseRng") (EVar "UseFloat") (EVar "UseFloatRng"))) (ETuple (ELit (LString "randomChar")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseRng"))) (ETuple (ELit (LString "setSeed")) (EListLit (EVar "UseRng"))) (ETuple (ELit (LString "randomState")) (EListLit (EVar "UseRng") (EVar "UseU64"))) (ETuple (ELit (LString "restoreRandomState")) (EListLit (EVar "UseRng") (EVar "UseU64"))) (ETuple (ELit (LString "hashInt")) (EListLit (EVar "UseHash"))) (ETuple (ELit (LString "hashFloat")) (EListLit (EVar "UseHash") (EVar "UseFloat") (EVar "UseFloatHash"))) (ETuple (ELit (LString "hashString")) (EListLit (EVar "UseHash"))) (ETuple (ELit (LString "hashChar")) (EListLit (EVar "UseHash"))) (ETuple (ELit (LString "hashBool")) (EListLit (EVar "UseHash"))) (ETuple (ELit (LString "intToFloat")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "floatToInt")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "floatRem")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "sqrt")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "cbrt")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "exp")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "log")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "log2")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "log10")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "sin")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "cos")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "tan")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "asin")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "acos")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "atan")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "sinh")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "cosh")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "tanh")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "floor")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "ceil")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "round")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "trunc")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "pow")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "atan2")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "hypot")) (EListLit (EVar "UseFloat") (EVar "UseMath"))) (ETuple (ELit (LString "intBitsToFloat")) (EListLit (EVar "UseFloat"))) (ETuple (ELit (LString "bytesToFloat64")) (EListLit (EVar "UseFloat") (EVar "UseArray"))) (ETuple (ELit (LString "floatToBytes64")) (EListLit (EVar "UseFloat") (EVar "UseArray"))) (ETuple (ELit (LString "floatToString")) (EListLit (EVar "UseStr") (EVar "UseFloat"))) (ETuple (ELit (LString "debugStringLit")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf"))) (ETuple (ELit (LString "debugCharLit")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf"))) (ETuple (ELit (LString "arrayLength")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayMake")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayMakeWith")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayGetUnsafe")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arraySetUnsafe")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayCopy")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayBlit")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayFill")) (EListLit (EVar "UseArray"))) (ETuple (ELit (LString "arrayFromList")) (EListLit (EVar "UseArray") (EVar "UseList"))) (ETuple (ELit (LString "u64Truncate")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64TruncateToInt")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64BitAnd")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64BitOr")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64BitXor")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64ShiftLeft")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64ShiftRight")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "u64MulHigh")) (EListLit (EVar "UseU64"))) (ETuple (ELit (LString "i64FromBits")) (EListLit (EVar "UseU64") (EVar "UseI64"))) (ETuple (ELit (LString "i64ToBits")) (EListLit (EVar "UseU64") (EVar "UseI64"))) (ETuple (ELit (LString "byteBlockMake")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockLength")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockGetUnsafe")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockSetUnsafe")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockCopyUnsafe")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockBlit")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockFromIntArray")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockToIntArray")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockFromString")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockToString")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "byteBlockWriteStdout")) (EListLit (EVar "UseStr") (EVar "UseArray") (EVar "UseByteBlock"))) (ETuple (ELit (LString "stringToChars")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrCodec") (EVar "UseArray"))) (ETuple (ELit (LString "stringFromChars")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrCodec") (EVar "UseArray"))) (ETuple (ELit (LString "stringToUtf8Bytes")) (EListLit (EVar "UseStr") (EVar "UseStrCodec") (EVar "UseArray"))) (ETuple (ELit (LString "stringFromUtf8Bytes")) (EListLit (EVar "UseStr") (EVar "UseStrCodec") (EVar "UseArray"))) (ETuple (ELit (LString "charToStr")) (EListLit (EVar "UseStrLeaf"))) (ETuple (ELit (LString "charFromCode")) (EListLit (EVar "UseCharFromCode"))) (ETuple (ELit (LString "stringSlice")) (EListLit (EVar "UseStrLeaf"))) (ETuple (ELit (LString "stringConcat")) (EListLit (EVar "UseStrLeaf"))) (ETuple (ELit (LString "stringIndexOf")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrSearch"))) (ETuple (ELit (LString "stringStartsWith")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf"))) (ETuple (ELit (LString "stringEndsWith")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf"))) (ETuple (ELit (LString "stringCountOccurrences")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrSearch"))) (ETuple (ELit (LString "stringLastIndexOf")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrSearch"))) (ETuple (ELit (LString "stringToInt")) (EListLit (EVar "UseStr") (EVar "UseStrToInt"))) (ETuple (ELit (LString "stringReverse")) (EListLit (EVar "UseStr") (EVar "UseStrReverse"))) (ETuple (ELit (LString "stringJoin")) (EListLit (EVar "UseStr") (EVar "UseList") (EVar "UseStrJoin"))) (ETuple (ELit (LString "stringCompare")) (EListLit (EVar "UseStr") (EVar "UseStrLeaf") (EVar "UseStrSearch"))) (ETuple (ELit (LString "stringToFloat")) (EListLit (EVar "UseStr") (EVar "UseFloat") (EVar "UseFloatStr"))) (ETuple (ELit (LString "charIsAlpha")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charIsSpace")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charIsUpper")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charIsLower")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charIsPunct")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charToUpper")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "charToLower")) (EListLit (EVar "UseCharClass"))) (ETuple (ELit (LString "stringToUpper")) (EListLit (EVar "UseStrLeaf"))) (ETuple (ELit (LString "stringToLower")) (EListLit (EVar "UseStrLeaf")))))
(DTypeSig false "interpLlvmOnly" (TyCon "String"))
(DFunDef false "interpLlvmOnly" () (ELit (LString "implemented by llvm, missing from the interpreter")))
(DTypeSig false "wasmNoSockets" (TyCon "String"))
(DFunDef false "wasmNoSockets" () (ELit (LString "the `net` module is native-only: raw BSD sockets have no WasmGC equivalent — build for a native target instead")))
(DTypeSig false "noHttpClient" (TyCon "String"))
(DFunDef false "noHttpClient" () (ELit (LString "`fetchText` is lowered only by the wasmgc/edge target: native has no HTTP client and no TLS — build for `wasmgc/edge`")))
(DTypeSig false "interpNoHttpClient" (TyCon "String"))
(DFunDef false "interpNoHttpClient" () (ELit (LString "the interpreter has no HTTP client; only the wasmgc/edge target lowers `fetchText`")))
(DTypeSig true "catalogRows" (TyApp (TyCon "List") (TyCon "ExternRow")))
(DFunDef false "catalogRows" () (EListLit (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "putStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_putstr")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "putStrLn"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_putstrln")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ePutStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_eputstr")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ePutStrLn"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_eputstrln")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "flushStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_flushstdout")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readLine"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_line")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readLineOpt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_line_opt")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readAll"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_all")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readExactly"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_exactly")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "Ref"))) (EApp (EVar "Inline") (EVar "LlvmRefCell"))) (EApp (EVar "Inline") (EVar "WasmRefCell"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "setRef"))) (EApp (EVar "Inline") (EVar "LlvmRefCell"))) (EApp (EVar "Inline") (EVar "WasmRefCell"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readFileBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_file_bytes")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFileBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file_bytes")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFileMode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file_mode")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "appendFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_append_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fileExists"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_file_exists")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fileMode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_file_mode")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "canonicalizePath"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_canonicalize_path")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "listDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_list_dir")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "makeDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_make_dir")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "removeFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_remove_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "rename"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_rename")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fsync"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_fsync")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "removeDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_remove_dir")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "statFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_stat_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "args"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmEnv")) (ELit (LString "mdk_args")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "getEnv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmEnv")) (ELit (LString "mdk_get_env")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "executablePath"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_executable_path")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildFingerprint"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_fingerprint")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "build-provenance (the staleness guard) is meaningless in the WasmGC playground — there is no build-provenance object linked in and no host filesystem to re-hash compiler/ against; the compiler is only ever built via the LLVM backend, never wasm")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildCommit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_commit")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "same rationale as buildFingerprint (a sibling provenance stamp) — no build-provenance object linked in and no host git checkout in the WasmGC playground")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildDate"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_date")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "same rationale as buildFingerprint (a sibling provenance stamp) — no build-provenance object linked into the WasmGC playground")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "runCommand"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_run_command")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "a subprocess has no WasmGC host equivalent: Exec is granted on native and run only, and no wasm profile grants it")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "implemented by llvm, missing from the interpreter on purpose: the interpreter waits on a decision about the --allow-exec security posture")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "runCommandBatch"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_run_command_batch")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "a subprocess has no WasmGC host equivalent: Exec is granted on native and run only, and no wasm profile grants it")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "implemented by llvm, missing from the interpreter on purpose: the same --allow-exec posture as runCommand")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "exit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_exit")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_exit")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "panic"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_panic")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexError"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_msg")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexErrorAt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_at")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexErrorAtSite"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_at")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "panicAt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_panic")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sliceError"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_slice_oob")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stashRunStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_stash_run_stdout")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "internal `medaka run` CLI plumbing (interpreter-only outputRef stash for the \"run drops stdout on panic\" fix) — the compiler is only ever built via the LLVM backend, never wasm, so no WasmGC program ever exercises this")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "enableRunStdoutFlush"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_enable_run_stdout_flush")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "internal `medaka run` CLI plumbing (arms the abort-time flush for the \"run drops stdout on panic\" fix) — the compiler is only ever built via the LLVM backend, never wasm, so no WasmGC program ever exercises this")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "__fallthrough__"))) (EApp (EVar "Inline") (EVar "LlvmFallthrough"))) (EApp (EVar "Inline") (EVar "WasmFallthrough"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "assertSnapshot"))) (EApp (EApp (EVar "NotProvided") (EVar "GapTodo")) (ELit (LString "unimplemented in all 3 engines, no stdlib caller — forward-declared snapshot-testing primitive, not an asymmetric regression")))) (EApp (EApp (EVar "NotProvided") (EVar "GapTodo")) (ELit (LString "unimplemented in all 3 engines, no stdlib caller — forward-declared snapshot-testing primitive, not an asymmetric regression")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "unimplemented in all 3 engines (see llvm/wasm TODO rows); no stdlib caller yet — a forward-declared snapshot-testing primitive (TESTING-DESIGN.md §4.7 \"medaka test --promote\"); recorded as a bug row for the interpreter although it is not an asymmetric regression against another engine")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netResolve"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_resolve")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpConnect"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_connect")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpListen"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_listen")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netListenPort"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_listen_port")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpAccept"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_accept")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSend"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSendFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netRecv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_recv")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netShutdown"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_shutdown")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netClose"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_close")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netCloseListener"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_close")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetTimeout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_timeout")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "socketFd"))) (EApp (EVar "Inline") (EVar "LlvmNet"))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "listenSocketFd"))) (EApp (EVar "Inline") (EVar "LlvmNet"))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pdsSignalStart"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_pds_signal_start")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "POSIX SIGTERM self-pipe and fd readiness are native-only; wasm_emit rejects the net family")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "the interpreter has no signal host binding yet, though the run profile grants Signal (TARGETS-DESIGN §8.1)")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pdsSignalRequested"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_pds_signal_requested")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "POSIX SIGTERM state is native-only; wasm_emit rejects the net family")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "the interpreter has no signal host binding yet, though the run profile grants Signal (TARGETS-DESIGN §8.1)")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ioPoll"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_io_poll")))) (EApp (EApp (EVar "TrapStub") (EVar "WasmLeaf")) (ELit (LString "bound to a coded runtime trap, not a value: E-WASM-NO-BINDING after evaluating its arguments; the Net/Stdin readiness bindings are #3666")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetNonblock"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_nonblock")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetNonblockListener"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_nonblock")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryAccept"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_accept")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netConnectStart"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_connect_start")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netConnectCheck"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_connect_check")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryRecv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_recv")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryRecvBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_recv_bytes")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySend"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySendFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSendBytesFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send_bytes_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySendBytesFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send_bytes_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "wallTimeSec"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_wall_time_sec")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_wall_time_sec")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "monotonicSec"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_monotonic_sec")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_monotonic_sec")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sleepMs"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_sleep_ms")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sleep_ms")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fetchText"))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "noHttpClient"))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_fetch_text")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "interpNoHttpClient"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "allocBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_alloc_bytes")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "real GC-byte-counter FFI in llvm, no wasm host-import wired")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomInt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_int")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomBool"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_bool")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomChar"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_char")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "setSeed"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_set_seed")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomState"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_state")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "restoreRandomState"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_restore_random_state")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "osEntropyBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_os_entropy_bytes")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashInt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_int")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashChar"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_char")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashBool"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_bool")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pi"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "e"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intMinBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intMaxBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charMinBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charMaxBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intToFloat"))) (EApp (EVar "Inline") (EVar "LlvmNum"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToInt"))) (EApp (EVar "Inline") (EVar "LlvmNum"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatRem"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_rem")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitAnd"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_and")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitOr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_or")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitXor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_xor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "shiftLeft"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_left")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "shiftRight"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_right")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitNot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_not")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sqrt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sqrt")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cbrt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cbrt")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cbrt")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "exp"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_exp")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_exp")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log2"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log2")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log2")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log10"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log10")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log10")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sin"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sin")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sin")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cos"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cos")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cos")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "tan"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_tan")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_tan")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "asin"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_asin")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_asin")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "acos"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_acos")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_acos")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "atan"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_atan")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_atan")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sinh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sinh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sinh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cosh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cosh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cosh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "tanh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_tanh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_tanh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_floor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ceil"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_ceil")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "round"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_round")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "trunc"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_trunc")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pow"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_pow")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_pow")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "atan2"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_atan2")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_atan2")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hypot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_hypot")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_hypot")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitsToFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_int_bits_to_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bytesToFloat64"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_bytes_to_float64")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToBytes64"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_to_bytes64")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_int_to_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_to_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "debugStringLit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmDebugLit")) (ELit (LString "mdk_debug_string_lit")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "debugCharLit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmDebugLit")) (ELit (LString "mdk_debug_char_lit")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayLength"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayMake"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_make")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayMakeWith"))) (EApp (EVar "Inline") (EVar "LlvmArrayMakeWith"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayGetUnsafe"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arraySetUnsafe"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayCopy"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_copy")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayBlit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_blit")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayFill"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_fill")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayFromList"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_from_list")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u8Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u8ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u16Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u16ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u32Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u32ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitAnd"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_and")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitOr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_or")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitXor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_xor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitNot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_not")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intShiftLeft"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_left")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intShiftRight"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_right")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64Truncate"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64TruncateToInt"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitAnd"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitOr"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitXor"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64ShiftLeft"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64ShiftRight"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64MulHigh"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i32Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i32ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i64FromBits"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i64ToBits"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockMake"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_make")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockLength"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_length")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockGetUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_get")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockSetUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_set")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockCopyUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_copy")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockBlit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_blit")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockFromIntArray"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_from_int_array")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockToIntArray"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_to_int_array")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockFromString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_from_string")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_to_string")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockWriteStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_byteblock_write_stdout")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToChars"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_to_chars")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringFromChars"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_from_chars")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToUtf8Bytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_to_utf8_bytes")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringFromUtf8Bytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_from_utf8_bytes")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmChar")) (ELit (LString "mdk_char_to_str")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charCode"))) (EApp (EVar "Inline") (EVar "LlvmChar"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charFromCode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_char_from_code")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringLength"))) (EApp (EVar "Inline") (EVar "LlvmStr"))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringByteLength"))) (EApp (EVar "Inline") (EVar "LlvmStr"))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringSlice"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_slice")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringConcat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_concat")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringIndexOf"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_index_of")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringStartsWith"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_starts_with")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringEndsWith"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_ends_with")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringCountOccurrences"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_count_occurrences")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringLastIndexOf"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_last_index_of")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToInt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_to_int")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringReverse"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_reverse")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringJoin"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_join")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringCompare"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_compare")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_to_float")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsAlpha"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_alpha")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsSpace"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_space")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_upper")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_lower")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsPunct"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_punct")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_to_upper")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_to_lower")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_string_to_upper")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_string_to_lower")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted"))))
