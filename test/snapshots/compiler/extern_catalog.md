# META
source_lines=1105
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

-- One extern: its name, then the llvm, wasm and eval dispositions.  The
-- interpreter selects through its own keyed tables, so its column has no family.
public export data ExternRow =
  | ExternRow String (Disposition LlvmFamily) (Disposition WasmFamily) (Disposition Unit)

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

catalogIndex : OrdMap ExternRow
catalogIndex = omFromPairs (map (r => (rowName r, r)) catalogRows) omEmpty

interpLlvmOnly : String
interpLlvmOnly = "implemented by llvm, missing from interp — BUG(T7)"

wasmNoSockets : String
wasmNoSockets =
  "raw BSD sockets have no WasmGC equivalent (wasm_emit.mdk gapL, ~line 4590/6311) — build for a native target instead"

wasmNoHostFs : String
wasmNoHostFs = "ported in llvm (isFileExtern), not yet in wasm's host-fs seam"

wasmNoStdin : String
wasmNoStdin = "ported in llvm (isFileExtern, stdin family), not yet in wasm"

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
    (NotProvided GapUnported wasmNoStdin)
    Interpreted,
  ExternRow
    "readLineOpt"
    (CSymbol LlvmFile "mdk_read_line_opt")
    (NotProvided GapUnported wasmNoStdin)
    Interpreted,
  ExternRow
    "readAll"
    (CSymbol LlvmFile "mdk_read_all")
    (NotProvided GapUnported wasmNoStdin)
    Interpreted,
  ExternRow
    "readExactly"
    (CSymbol LlvmFile "mdk_read_exactly")
    (NotProvided GapUnported wasmNoStdin)
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
    (NotProvided
      GapUnported
      "ported in llvm (isFileExtern); wasm has writeFileBytes but not the text-mode writeFile")
    Interpreted,
  ExternRow
    "writeFileBytes"
    (CSymbol LlvmFile "mdk_write_file_bytes")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "writeFileMode"
    (CSymbol LlvmFile "mdk_write_file_mode")
    (NotProvided
      GapUnported
      "ported in llvm (isFileExtern), not yet in wasm's host-fs seam; the browser playground has no POSIX file mode to set")
    Interpreted,
  ExternRow
    "appendFile"
    (CSymbol LlvmFile "mdk_append_file")
    (NotProvided GapUnported wasmNoHostFs)
    Interpreted,
  ExternRow
    "fileExists"
    (CSymbol LlvmFile "mdk_file_exists")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "fileMode"
    (CSymbol LlvmFile "mdk_file_mode")
    (NotProvided
      GapUnported
      "ported in llvm (isFileExtern), not yet in wasm's host-fs seam; the browser playground has no POSIX file mode to report")
    Interpreted,
  ExternRow
    "canonicalizePath"
    (CSymbol LlvmFile "mdk_canonicalize_path")
    (Inline WasmLeaf)
    Interpreted,
  ExternRow
    "listDir"
    (CSymbol LlvmFile "mdk_list_dir")
    (NotProvided GapUnported wasmNoHostFs)
    Interpreted,
  ExternRow
    "makeDir"
    (CSymbol LlvmFile "mdk_make_dir")
    (NotProvided GapUnported wasmNoHostFs)
    Interpreted,
  ExternRow
    "removeFile"
    (CSymbol LlvmFile "mdk_remove_file")
    (NotProvided GapUnported wasmNoHostFs)
    Interpreted,
  ExternRow
    "rename"
    (CSymbol LlvmFile "mdk_rename")
    (NotProvided GapUnported wasmNoHostFs)
    Interpreted,
  ExternRow
    "fsync"
    (CSymbol LlvmFile "mdk_fsync")
    (NotProvided GapUnported wasmNoHostFs)
    Interpreted,
  ExternRow
    "removeDir"
    (CSymbol LlvmFile "mdk_remove_dir")
    (NotProvided GapUnported wasmNoHostFs)
    Interpreted,
  ExternRow
    "statFile"
    (CSymbol LlvmFile "mdk_stat_file")
    (NotProvided GapUnported wasmNoHostFs)
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
    (NotProvided GapUnported "ported in llvm (isEnvExtern), not yet in wasm")
    Interpreted,
  ExternRow
    "buildFingerprint"
    (CSymbol LlvmFile "mdk_build_fingerprint")
    (NotProvided
      GapPermanent
      "build-provenance (issue #89 staleness guard) is meaningless in the WasmGC playground — there is no build-provenance object linked in and no host filesystem to re-hash compiler/ against; the compiler is only ever built via the LLVM backend, never wasm")
    Interpreted,
  ExternRow
    "buildCommit"
    (CSymbol LlvmFile "mdk_build_commit")
    (NotProvided
      GapPermanent
      "same rationale as buildFingerprint (issue #74 W8 sibling stamp) — no build-provenance object linked in and no host git checkout in the WasmGC playground")
    Interpreted,
  ExternRow
    "buildDate"
    (CSymbol LlvmFile "mdk_build_date")
    (NotProvided
      GapPermanent
      "same rationale as buildFingerprint (issue #74 W8 sibling stamp) — no build-provenance object linked in in the WasmGC playground")
    Interpreted,
  ExternRow
    "runCommand"
    (CSymbol LlvmFile "mdk_run_command")
    (NotProvided
      GapPermanent
      "a subprocess has no WasmGC host equivalent: Exec is granted on native and run only, and no wasm profile grants it")
    (NotProvided
      GapBug
      "implemented by llvm (isFileExtern family), missing from interp — BUG(T7). DEFERRED ON PURPOSE (2026-07-13): --allow-exec security posture first"),
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
      "unimplemented in all 3 engines (see llvm/wasm TODO rows); no stdlib caller yet — a forward-declared snapshot-testing primitive (TESTING-DESIGN.md §4.7 \"medaka test --promote\"); filed BUG(T7) here per the 37-count framing even though it isn't an asymmetric regression against another engine"),
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
    "allocBytes"
    (CSymbol LlvmPerf "mdk_alloc_bytes")
    (NotProvided
      GapUnported
      "real GC-byte-counter FFI in llvm (isPerfExtern), no wasm host-import wired")
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
    (NotProvided
      GapUnported
      "OS/browser entropy host import is not wired; native/eval only (#1726)")
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
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omLookup" false))))
(DData Public "GapKind" () ((variant "GapBug" (ConPos)) (variant "GapDead" (ConPos)) (variant "GapTodo" (ConPos)) (variant "GapPermanent" (ConPos)) (variant "GapUnported" (ConPos))) ())
(DData Public "Disposition" ("f") ((variant "CSymbol" (ConPos (TyVar "f") (TyCon "String"))) (variant "EnvImport" (ConPos (TyVar "f") (TyCon "String"))) (variant "Inline" (ConPos (TyVar "f"))) (variant "Interpreted" (ConPos)) (variant "TrapStub" (ConPos (TyVar "f") (TyCon "String"))) (variant "FrozenConstant" (ConPos (TyVar "f") (TyCon "String"))) (variant "NotProvided" (ConPos (TyCon "GapKind") (TyCon "String")))) ())
(DData Public "LlvmFamily" () ((variant "LlvmStr" (ConPos)) (variant "LlvmNum" (ConPos)) (variant "LlvmIo" (ConPos)) (variant "LlvmAbort" (ConPos)) (variant "LlvmArrIntrinsic" (ConPos)) (variant "LlvmArrLeaf" (ConPos)) (variant "LlvmByteBlock" (ConPos)) (variant "LlvmChar" (ConPos)) (variant "LlvmStrChar" (ConPos)) (variant "LlvmUnicode" (ConPos)) (variant "LlvmAdt" (ConPos)) (variant "LlvmEnv" (ConPos)) (variant "LlvmFile" (ConPos)) (variant "LlvmNet" (ConPos)) (variant "LlvmRng" (ConPos)) (variant "LlvmHash" (ConPos)) (variant "LlvmBit" (ConPos)) (variant "LlvmFixedWidth" (ConPos)) (variant "LlvmU64" (ConPos)) (variant "LlvmDebugLit" (ConPos)) (variant "LlvmPerf" (ConPos)) (variant "LlvmArrayMakeWith" (ConPos)) (variant "LlvmRefCell" (ConPos)) (variant "LlvmConstant" (ConPos)) (variant "LlvmFallthrough" (ConPos))) ())
(DData Public "WasmFamily" () ((variant "WasmStr" (ConPos)) (variant "WasmLeaf" (ConPos)) (variant "WasmArray" (ConPos)) (variant "WasmByteBlock" (ConPos)) (variant "WasmRefCell" (ConPos)) (variant "WasmConstant" (ConPos)) (variant "WasmFallthrough" (ConPos))) ())
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
(DTypeSig false "catalogIndex" (TyApp (TyCon "OrdMap") (TyCon "ExternRow")))
(DFunDef false "catalogIndex" () (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "rowName") (EVar "r")) (EVar "r")))) (EVar "catalogRows"))) (EVar "omEmpty")))
(DTypeSig false "interpLlvmOnly" (TyCon "String"))
(DFunDef false "interpLlvmOnly" () (ELit (LString "implemented by llvm, missing from interp — BUG(T7)")))
(DTypeSig false "wasmNoSockets" (TyCon "String"))
(DFunDef false "wasmNoSockets" () (ELit (LString "raw BSD sockets have no WasmGC equivalent (wasm_emit.mdk gapL, ~line 4590/6311) — build for a native target instead")))
(DTypeSig false "wasmNoHostFs" (TyCon "String"))
(DFunDef false "wasmNoHostFs" () (ELit (LString "ported in llvm (isFileExtern), not yet in wasm's host-fs seam")))
(DTypeSig false "wasmNoStdin" (TyCon "String"))
(DFunDef false "wasmNoStdin" () (ELit (LString "ported in llvm (isFileExtern, stdin family), not yet in wasm")))
(DTypeSig true "catalogRows" (TyApp (TyCon "List") (TyCon "ExternRow")))
(DFunDef false "catalogRows" () (EListLit (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "putStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_putstr")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "putStrLn"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_putstrln")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ePutStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_eputstr")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ePutStrLn"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_eputstrln")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "flushStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_flushstdout")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readLine"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_line")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoStdin"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readLineOpt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_line_opt")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoStdin"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readAll"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_all")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoStdin"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readExactly"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_exactly")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoStdin"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "Ref"))) (EApp (EVar "Inline") (EVar "LlvmRefCell"))) (EApp (EVar "Inline") (EVar "WasmRefCell"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "setRef"))) (EApp (EVar "Inline") (EVar "LlvmRefCell"))) (EApp (EVar "Inline") (EVar "WasmRefCell"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readFileBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_file_bytes")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "ported in llvm (isFileExtern); wasm has writeFileBytes but not the text-mode writeFile")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFileBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file_bytes")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFileMode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file_mode")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "ported in llvm (isFileExtern), not yet in wasm's host-fs seam; the browser playground has no POSIX file mode to set")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "appendFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_append_file")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fileExists"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_file_exists")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fileMode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_file_mode")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "ported in llvm (isFileExtern), not yet in wasm's host-fs seam; the browser playground has no POSIX file mode to report")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "canonicalizePath"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_canonicalize_path")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "listDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_list_dir")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "makeDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_make_dir")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "removeFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_remove_file")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "rename"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_rename")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fsync"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_fsync")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "removeDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_remove_dir")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "statFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_stat_file")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "args"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmEnv")) (ELit (LString "mdk_args")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "getEnv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmEnv")) (ELit (LString "mdk_get_env")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "executablePath"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_executable_path")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "ported in llvm (isEnvExtern), not yet in wasm")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildFingerprint"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_fingerprint")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "build-provenance (issue #89 staleness guard) is meaningless in the WasmGC playground — there is no build-provenance object linked in and no host filesystem to re-hash compiler/ against; the compiler is only ever built via the LLVM backend, never wasm")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildCommit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_commit")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "same rationale as buildFingerprint (issue #74 W8 sibling stamp) — no build-provenance object linked in and no host git checkout in the WasmGC playground")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildDate"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_date")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "same rationale as buildFingerprint (issue #74 W8 sibling stamp) — no build-provenance object linked in in the WasmGC playground")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "runCommand"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_run_command")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "a subprocess has no WasmGC host equivalent: Exec is granted on native and run only, and no wasm profile grants it")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "implemented by llvm (isFileExtern family), missing from interp — BUG(T7). DEFERRED ON PURPOSE (2026-07-13): --allow-exec security posture first")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "exit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_exit")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_exit")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "panic"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_panic")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexError"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_msg")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexErrorAt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_at")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexErrorAtSite"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_at")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "panicAt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_panic")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sliceError"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_slice_oob")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stashRunStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_stash_run_stdout")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "internal `medaka run` CLI plumbing (interpreter-only outputRef stash for the \"run drops stdout on panic\" fix) — the compiler is only ever built via the LLVM backend, never wasm, so no WasmGC program ever exercises this")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "enableRunStdoutFlush"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_enable_run_stdout_flush")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "internal `medaka run` CLI plumbing (arms the abort-time flush for the \"run drops stdout on panic\" fix) — the compiler is only ever built via the LLVM backend, never wasm, so no WasmGC program ever exercises this")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "__fallthrough__"))) (EApp (EVar "Inline") (EVar "LlvmFallthrough"))) (EApp (EVar "Inline") (EVar "WasmFallthrough"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "assertSnapshot"))) (EApp (EApp (EVar "NotProvided") (EVar "GapTodo")) (ELit (LString "unimplemented in all 3 engines, no stdlib caller — forward-declared snapshot-testing primitive, not an asymmetric regression")))) (EApp (EApp (EVar "NotProvided") (EVar "GapTodo")) (ELit (LString "unimplemented in all 3 engines, no stdlib caller — forward-declared snapshot-testing primitive, not an asymmetric regression")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "unimplemented in all 3 engines (see llvm/wasm TODO rows); no stdlib caller yet — a forward-declared snapshot-testing primitive (TESTING-DESIGN.md §4.7 \"medaka test --promote\"); filed BUG(T7) here per the 37-count framing even though it isn't an asymmetric regression against another engine")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netResolve"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_resolve")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpConnect"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_connect")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpListen"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_listen")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netListenPort"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_listen_port")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpAccept"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_accept")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSend"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSendFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netRecv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_recv")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netShutdown"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_shutdown")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netClose"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_close")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netCloseListener"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_close")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetTimeout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_timeout")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "socketFd"))) (EApp (EVar "Inline") (EVar "LlvmNet"))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "listenSocketFd"))) (EApp (EVar "Inline") (EVar "LlvmNet"))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pdsSignalStart"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_pds_signal_start")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "POSIX SIGTERM self-pipe and fd readiness are native-only; wasm_emit rejects the net family")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "the interpreter has no signal host binding yet, though the run profile grants Signal (TARGETS-DESIGN §8.1)")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pdsSignalRequested"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_pds_signal_requested")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "POSIX SIGTERM state is native-only; wasm_emit rejects the net family")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "the interpreter has no signal host binding yet, though the run profile grants Signal (TARGETS-DESIGN §8.1)")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ioPoll"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_io_poll")))) (EApp (EApp (EVar "TrapStub") (EVar "WasmLeaf")) (ELit (LString "bound to a coded runtime trap, not a value: E-WASM-NO-BINDING after evaluating its arguments; the Net/Stdin readiness bindings are #3666")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetNonblock"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_nonblock")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetNonblockListener"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_nonblock")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryAccept"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_accept")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netConnectStart"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_connect_start")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netConnectCheck"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_connect_check")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryRecv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_recv")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryRecvBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_recv_bytes")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySend"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySendFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSendBytesFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send_bytes_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySendBytesFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send_bytes_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "wallTimeSec"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_wall_time_sec")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_wall_time_sec")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "monotonicSec"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_monotonic_sec")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_monotonic_sec")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sleepMs"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_sleep_ms")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sleep_ms")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "allocBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_alloc_bytes")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "real GC-byte-counter FFI in llvm (isPerfExtern), no wasm host-import wired")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomInt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_int")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomBool"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_bool")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomChar"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_char")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "setSeed"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_set_seed")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomState"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_state")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "restoreRandomState"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_restore_random_state")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "osEntropyBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_os_entropy_bytes")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "OS/browser entropy host import is not wired; native/eval only (#1726)")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashInt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_int")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashChar"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_char")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashBool"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_bool")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pi"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "e"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intMinBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intMaxBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charMinBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charMaxBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intToFloat"))) (EApp (EVar "Inline") (EVar "LlvmNum"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToInt"))) (EApp (EVar "Inline") (EVar "LlvmNum"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatRem"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_rem")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitAnd"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_and")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitOr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_or")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitXor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_xor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "shiftLeft"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_left")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "shiftRight"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_right")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitNot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_not")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sqrt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sqrt")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cbrt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cbrt")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cbrt")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "exp"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_exp")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_exp")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log2"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log2")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log2")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log10"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log10")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log10")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sin"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sin")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sin")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cos"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cos")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cos")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "tan"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_tan")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_tan")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "asin"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_asin")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_asin")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "acos"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_acos")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_acos")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "atan"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_atan")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_atan")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sinh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sinh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sinh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cosh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cosh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cosh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "tanh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_tanh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_tanh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_floor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ceil"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_ceil")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "round"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_round")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "trunc"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_trunc")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pow"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_pow")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_pow")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "atan2"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_atan2")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_atan2")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hypot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_hypot")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_hypot")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitsToFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_int_bits_to_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bytesToFloat64"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_bytes_to_float64")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToBytes64"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_to_bytes64")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_int_to_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_to_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "debugStringLit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmDebugLit")) (ELit (LString "mdk_debug_string_lit")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "debugCharLit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmDebugLit")) (ELit (LString "mdk_debug_char_lit")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayLength"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayMake"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_make")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayMakeWith"))) (EApp (EVar "Inline") (EVar "LlvmArrayMakeWith"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayGetUnsafe"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arraySetUnsafe"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayCopy"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_copy")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayBlit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_blit")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayFill"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_fill")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayFromList"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_from_list")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u8Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u8ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u16Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u16ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u32Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u32ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitAnd"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_and")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitOr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_or")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitXor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_xor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitNot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_not")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intShiftLeft"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_left")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intShiftRight"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_right")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64Truncate"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64TruncateToInt"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitAnd"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitOr"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitXor"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64ShiftLeft"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64ShiftRight"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64MulHigh"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i32Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i32ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i64FromBits"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i64ToBits"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockMake"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_make")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockLength"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_length")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockGetUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_get")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockSetUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_set")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockCopyUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_copy")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockBlit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_blit")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockFromIntArray"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_from_int_array")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockToIntArray"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_to_int_array")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockFromString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_from_string")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_to_string")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockWriteStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_byteblock_write_stdout")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToChars"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_to_chars")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringFromChars"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_from_chars")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToUtf8Bytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_to_utf8_bytes")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringFromUtf8Bytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_from_utf8_bytes")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmChar")) (ELit (LString "mdk_char_to_str")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charCode"))) (EApp (EVar "Inline") (EVar "LlvmChar"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charFromCode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_char_from_code")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringLength"))) (EApp (EVar "Inline") (EVar "LlvmStr"))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringSlice"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_slice")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringConcat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_concat")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringIndexOf"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_index_of")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringCompare"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_compare")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_to_float")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsAlpha"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_alpha")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsSpace"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_space")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_upper")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_lower")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsPunct"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_punct")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_to_upper")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_to_lower")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_string_to_upper")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_string_to_lower")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted"))))
# MARK
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omLookup" false))))
(DData Public "GapKind" () ((variant "GapBug" (ConPos)) (variant "GapDead" (ConPos)) (variant "GapTodo" (ConPos)) (variant "GapPermanent" (ConPos)) (variant "GapUnported" (ConPos))) ())
(DData Public "Disposition" ("f") ((variant "CSymbol" (ConPos (TyVar "f") (TyCon "String"))) (variant "EnvImport" (ConPos (TyVar "f") (TyCon "String"))) (variant "Inline" (ConPos (TyVar "f"))) (variant "Interpreted" (ConPos)) (variant "TrapStub" (ConPos (TyVar "f") (TyCon "String"))) (variant "FrozenConstant" (ConPos (TyVar "f") (TyCon "String"))) (variant "NotProvided" (ConPos (TyCon "GapKind") (TyCon "String")))) ())
(DData Public "LlvmFamily" () ((variant "LlvmStr" (ConPos)) (variant "LlvmNum" (ConPos)) (variant "LlvmIo" (ConPos)) (variant "LlvmAbort" (ConPos)) (variant "LlvmArrIntrinsic" (ConPos)) (variant "LlvmArrLeaf" (ConPos)) (variant "LlvmByteBlock" (ConPos)) (variant "LlvmChar" (ConPos)) (variant "LlvmStrChar" (ConPos)) (variant "LlvmUnicode" (ConPos)) (variant "LlvmAdt" (ConPos)) (variant "LlvmEnv" (ConPos)) (variant "LlvmFile" (ConPos)) (variant "LlvmNet" (ConPos)) (variant "LlvmRng" (ConPos)) (variant "LlvmHash" (ConPos)) (variant "LlvmBit" (ConPos)) (variant "LlvmFixedWidth" (ConPos)) (variant "LlvmU64" (ConPos)) (variant "LlvmDebugLit" (ConPos)) (variant "LlvmPerf" (ConPos)) (variant "LlvmArrayMakeWith" (ConPos)) (variant "LlvmRefCell" (ConPos)) (variant "LlvmConstant" (ConPos)) (variant "LlvmFallthrough" (ConPos))) ())
(DData Public "WasmFamily" () ((variant "WasmStr" (ConPos)) (variant "WasmLeaf" (ConPos)) (variant "WasmArray" (ConPos)) (variant "WasmByteBlock" (ConPos)) (variant "WasmRefCell" (ConPos)) (variant "WasmConstant" (ConPos)) (variant "WasmFallthrough" (ConPos))) ())
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
(DTypeSig false "catalogIndex" (TyApp (TyCon "OrdMap") (TyCon "ExternRow")))
(DFunDef false "catalogIndex" () (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "rowName") (EVar "r")) (EVar "r")))) (EVar "catalogRows"))) (EVar "omEmpty")))
(DTypeSig false "interpLlvmOnly" (TyCon "String"))
(DFunDef false "interpLlvmOnly" () (ELit (LString "implemented by llvm, missing from interp — BUG(T7)")))
(DTypeSig false "wasmNoSockets" (TyCon "String"))
(DFunDef false "wasmNoSockets" () (ELit (LString "raw BSD sockets have no WasmGC equivalent (wasm_emit.mdk gapL, ~line 4590/6311) — build for a native target instead")))
(DTypeSig false "wasmNoHostFs" (TyCon "String"))
(DFunDef false "wasmNoHostFs" () (ELit (LString "ported in llvm (isFileExtern), not yet in wasm's host-fs seam")))
(DTypeSig false "wasmNoStdin" (TyCon "String"))
(DFunDef false "wasmNoStdin" () (ELit (LString "ported in llvm (isFileExtern, stdin family), not yet in wasm")))
(DTypeSig true "catalogRows" (TyApp (TyCon "List") (TyCon "ExternRow")))
(DFunDef false "catalogRows" () (EListLit (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "putStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_putstr")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "putStrLn"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_putstrln")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ePutStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_eputstr")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ePutStrLn"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_eputstrln")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "flushStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_flushstdout")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readLine"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_line")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoStdin"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readLineOpt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_line_opt")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoStdin"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readAll"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_all")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoStdin"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readExactly"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_exactly")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoStdin"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "Ref"))) (EApp (EVar "Inline") (EVar "LlvmRefCell"))) (EApp (EVar "Inline") (EVar "WasmRefCell"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "setRef"))) (EApp (EVar "Inline") (EVar "LlvmRefCell"))) (EApp (EVar "Inline") (EVar "WasmRefCell"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_file")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "readFileBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_read_file_bytes")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "ported in llvm (isFileExtern); wasm has writeFileBytes but not the text-mode writeFile")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFileBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file_bytes")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "writeFileMode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_write_file_mode")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "ported in llvm (isFileExtern), not yet in wasm's host-fs seam; the browser playground has no POSIX file mode to set")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "appendFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_append_file")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fileExists"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_file_exists")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fileMode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_file_mode")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "ported in llvm (isFileExtern), not yet in wasm's host-fs seam; the browser playground has no POSIX file mode to report")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "canonicalizePath"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_canonicalize_path")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "listDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_list_dir")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "makeDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_make_dir")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "removeFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_remove_file")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "rename"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_rename")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "fsync"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_fsync")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "removeDir"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_remove_dir")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "statFile"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_stat_file")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (EVar "wasmNoHostFs"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "args"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmEnv")) (ELit (LString "mdk_args")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "getEnv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmEnv")) (ELit (LString "mdk_get_env")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "executablePath"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_executable_path")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "ported in llvm (isEnvExtern), not yet in wasm")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildFingerprint"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_fingerprint")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "build-provenance (issue #89 staleness guard) is meaningless in the WasmGC playground — there is no build-provenance object linked in and no host filesystem to re-hash compiler/ against; the compiler is only ever built via the LLVM backend, never wasm")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildCommit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_commit")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "same rationale as buildFingerprint (issue #74 W8 sibling stamp) — no build-provenance object linked in and no host git checkout in the WasmGC playground")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "buildDate"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_build_date")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "same rationale as buildFingerprint (issue #74 W8 sibling stamp) — no build-provenance object linked in in the WasmGC playground")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "runCommand"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmFile")) (ELit (LString "mdk_run_command")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "a subprocess has no WasmGC host equivalent: Exec is granted on native and run only, and no wasm profile grants it")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "implemented by llvm (isFileExtern family), missing from interp — BUG(T7). DEFERRED ON PURPOSE (2026-07-13): --allow-exec security posture first")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "exit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_exit")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_exit")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "panic"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_panic")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexError"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_msg")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexErrorAt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_at")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "indexErrorAtSite"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_oob_at")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "panicAt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_panic")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sliceError"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAbort")) (ELit (LString "mdk_slice_oob")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stashRunStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_stash_run_stdout")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "internal `medaka run` CLI plumbing (interpreter-only outputRef stash for the \"run drops stdout on panic\" fix) — the compiler is only ever built via the LLVM backend, never wasm, so no WasmGC program ever exercises this")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "enableRunStdoutFlush"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_enable_run_stdout_flush")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "internal `medaka run` CLI plumbing (arms the abort-time flush for the \"run drops stdout on panic\" fix) — the compiler is only ever built via the LLVM backend, never wasm, so no WasmGC program ever exercises this")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "__fallthrough__"))) (EApp (EVar "Inline") (EVar "LlvmFallthrough"))) (EApp (EVar "Inline") (EVar "WasmFallthrough"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "assertSnapshot"))) (EApp (EApp (EVar "NotProvided") (EVar "GapTodo")) (ELit (LString "unimplemented in all 3 engines, no stdlib caller — forward-declared snapshot-testing primitive, not an asymmetric regression")))) (EApp (EApp (EVar "NotProvided") (EVar "GapTodo")) (ELit (LString "unimplemented in all 3 engines, no stdlib caller — forward-declared snapshot-testing primitive, not an asymmetric regression")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "unimplemented in all 3 engines (see llvm/wasm TODO rows); no stdlib caller yet — a forward-declared snapshot-testing primitive (TESTING-DESIGN.md §4.7 \"medaka test --promote\"); filed BUG(T7) here per the 37-count framing even though it isn't an asymmetric regression against another engine")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netResolve"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_resolve")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpConnect"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_connect")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpListen"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_listen")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netListenPort"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_listen_port")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTcpAccept"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_tcp_accept")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSend"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSendFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netRecv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_recv")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netShutdown"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_shutdown")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netClose"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_close")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netCloseListener"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_close")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetTimeout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_timeout")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "socketFd"))) (EApp (EVar "Inline") (EVar "LlvmNet"))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "listenSocketFd"))) (EApp (EVar "Inline") (EVar "LlvmNet"))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pdsSignalStart"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_pds_signal_start")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "POSIX SIGTERM self-pipe and fd readiness are native-only; wasm_emit rejects the net family")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "the interpreter has no signal host binding yet, though the run profile grants Signal (TARGETS-DESIGN §8.1)")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pdsSignalRequested"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_pds_signal_requested")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (ELit (LString "POSIX SIGTERM state is native-only; wasm_emit rejects the net family")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (ELit (LString "the interpreter has no signal host binding yet, though the run profile grants Signal (TARGETS-DESIGN §8.1)")))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ioPoll"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_io_poll")))) (EApp (EApp (EVar "TrapStub") (EVar "WasmLeaf")) (ELit (LString "bound to a coded runtime trap, not a value: E-WASM-NO-BINDING after evaluating its arguments; the Net/Stdin readiness bindings are #3666")))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetNonblock"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_nonblock")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSetNonblockListener"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_set_nonblock")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryAccept"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_accept")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netConnectStart"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_connect_start")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netConnectCheck"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_connect_check")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryRecv"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_recv")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTryRecvBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_recv_bytes")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySend"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySendFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netSendBytesFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_send_bytes_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "netTrySendBytesFrom"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNet")) (ELit (LString "mdk_net_try_send_bytes_from")))) (EApp (EApp (EVar "NotProvided") (EVar "GapPermanent")) (EVar "wasmNoSockets"))) (EApp (EApp (EVar "NotProvided") (EVar "GapBug")) (EVar "interpLlvmOnly"))) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "wallTimeSec"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_wall_time_sec")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_wall_time_sec")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "monotonicSec"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_monotonic_sec")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_monotonic_sec")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sleepMs"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_sleep_ms")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sleep_ms")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "allocBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmPerf")) (ELit (LString "mdk_alloc_bytes")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "real GC-byte-counter FFI in llvm (isPerfExtern), no wasm host-import wired")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomInt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_int")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomBool"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_bool")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomChar"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_char")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "setSeed"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_set_seed")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "randomState"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_random_state")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "restoreRandomState"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_restore_random_state")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "osEntropyBytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmRng")) (ELit (LString "mdk_os_entropy_bytes")))) (EApp (EApp (EVar "NotProvided") (EVar "GapUnported")) (ELit (LString "OS/browser entropy host import is not wired; native/eval only (#1726)")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashInt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_int")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashChar"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_char")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hashBool"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmHash")) (ELit (LString "mdk_hash_bool")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pi"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "e"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intMinBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intMaxBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charMinBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charMaxBound"))) (EApp (EVar "Inline") (EVar "LlvmConstant"))) (EApp (EVar "Inline") (EVar "WasmConstant"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intToFloat"))) (EApp (EVar "Inline") (EVar "LlvmNum"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToInt"))) (EApp (EVar "Inline") (EVar "LlvmNum"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatRem"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_rem")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitAnd"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_and")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitOr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_or")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitXor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_xor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "shiftLeft"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_left")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "shiftRight"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_right")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bitNot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_not")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sqrt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sqrt")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cbrt"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cbrt")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cbrt")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "exp"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_exp")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_exp")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log2"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log2")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log2")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "log10"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_log10")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_log10")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sin"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sin")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sin")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cos"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cos")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cos")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "tan"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_tan")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_tan")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "asin"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_asin")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_asin")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "acos"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_acos")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_acos")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "atan"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_atan")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_atan")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "sinh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_sinh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_sinh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "cosh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_cosh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_cosh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "tanh"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_tanh")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_tanh")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_floor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "ceil"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_ceil")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "round"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_round")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "trunc"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_trunc")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "pow"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_pow")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_pow")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "atan2"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_atan2")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_atan2")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "hypot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_hypot")))) (EApp (EApp (EVar "EnvImport") (EVar "WasmLeaf")) (ELit (LString "mdk_hypot")))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitsToFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_int_bits_to_float")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "bytesToFloat64"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_bytes_to_float64")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToBytes64"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_to_bytes64")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_int_to_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "floatToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmNum")) (ELit (LString "mdk_float_to_string")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "debugStringLit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmDebugLit")) (ELit (LString "mdk_debug_string_lit")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "debugCharLit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmDebugLit")) (ELit (LString "mdk_debug_char_lit")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayLength"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayMake"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_make")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayMakeWith"))) (EApp (EVar "Inline") (EVar "LlvmArrayMakeWith"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayGetUnsafe"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arraySetUnsafe"))) (EApp (EVar "Inline") (EVar "LlvmArrIntrinsic"))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayCopy"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_copy")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayBlit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_blit")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayFill"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_fill")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "arrayFromList"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmArrLeaf")) (ELit (LString "mdk_array_from_list")))) (EApp (EVar "Inline") (EVar "WasmArray"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u8Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u8ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u16Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u16ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u32Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u32ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitAnd"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_and")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitOr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_or")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitXor"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_xor")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intBitNot"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_bit_not")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intShiftLeft"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_left")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "intShiftRight"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmBit")) (ELit (LString "mdk_shift_right")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64Truncate"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64TruncateToInt"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitAnd"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitOr"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64BitXor"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64ShiftLeft"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64ShiftRight"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "u64MulHigh"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i32Truncate"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i32ToInt"))) (EApp (EVar "Inline") (EVar "LlvmFixedWidth"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i64FromBits"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "i64ToBits"))) (EApp (EVar "Inline") (EVar "LlvmU64"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockMake"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_make")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockLength"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_length")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockGetUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_get")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockSetUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_set")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockCopyUnsafe"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_copy")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockBlit"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_blit")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockFromIntArray"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_from_int_array")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockToIntArray"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_to_int_array")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockFromString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_from_string")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockToString"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmByteBlock")) (ELit (LString "mdk_byteblock_to_string")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "byteBlockWriteStdout"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmIo")) (ELit (LString "mdk_byteblock_write_stdout")))) (EApp (EVar "Inline") (EVar "WasmByteBlock"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToChars"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_to_chars")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringFromChars"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_from_chars")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToUtf8Bytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_to_utf8_bytes")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringFromUtf8Bytes"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_from_utf8_bytes")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToStr"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmChar")) (ELit (LString "mdk_char_to_str")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charCode"))) (EApp (EVar "Inline") (EVar "LlvmChar"))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charFromCode"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_char_from_code")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringLength"))) (EApp (EVar "Inline") (EVar "LlvmStr"))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringSlice"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStrChar")) (ELit (LString "mdk_string_slice")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringConcat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmStr")) (ELit (LString "mdk_string_concat")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringIndexOf"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_index_of")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringCompare"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_compare")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToFloat"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmAdt")) (ELit (LString "mdk_string_to_float")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsAlpha"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_alpha")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsSpace"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_space")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_upper")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_lower")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charIsPunct"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_is_punct")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_to_upper")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "charToLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_char_to_lower")))) (EApp (EVar "Inline") (EVar "WasmLeaf"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToUpper"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_string_to_upper")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted")) (EApp (EApp (EApp (EApp (EVar "ExternRow") (ELit (LString "stringToLower"))) (EApp (EApp (EVar "CSymbol") (EVar "LlvmUnicode")) (ELit (LString "mdk_string_to_lower")))) (EApp (EVar "Inline") (EVar "WasmStr"))) (EVar "Interpreted"))))
