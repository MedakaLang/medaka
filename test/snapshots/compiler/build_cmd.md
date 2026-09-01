# META
source_lines=1096
stages=DESUGAR,MARK
# SOURCE
-- compiler/driver/build_cmd.mdk — `medaka build` ported to self-hosted Medaka
-- (Stage 4 Phase B.11).  The self-host analog of lib/build_cmd.ml: compile a
-- user .mdk program to a native binary via the Medaka-hosted LLVM emitter
-- (compiler/entries/llvm_emit_modules_main.mdk) + clang + the C runtime + Boehm GC.
--
-- EMIT STEP = SHELL-OUT (option b), mirroring lib/build_cmd.ml verbatim.  The
-- emitter is a heavy Medaka program carrying global Ref state (arg-stamp tables,
-- gap log) and writes IR to stdout via putStr.  Driving it in-process would mean
-- importing the entire emitter module graph into this driver AND risking Ref
-- bleed across the build's own elaboration — exactly the fragility the OCaml
-- driver cites for shelling out.  Running a FRESH `medaka run <emitter> …`
-- subprocess gives a clean stdout pipe and pristine Ref state per build, which is
-- what every working harness (test/diff_compiler_llvm_modules.sh, build_cmd.sh)
-- already relies on.  runCommand (#18, native-emittable) is the new capability
-- that makes this expressible in Medaka.
--
-- PATHS.  Selfhost has no Sys.executable_name / getcwd extern, so the driver
-- reads the medaka exe and repo root from the environment (MEDAKA, MEDAKA_ROOT)
-- — supplied by the gate script — falling back to "medaka" / "." .  Backend
-- assets (runtime.mdk, core.mdk, the emitter, medaka_rt.c, the compiler + stdlib
-- dirs) resolve repo-relative exactly as build_cmd.ml does.
--
-- GAP POLICY.  Hard-error (mirrors the MVP): a non-zero emitter exit (an
-- unemittable construct → `panic: … gap …`) or empty IR aborts the build with
-- the emitter's own diagnostic surfaced.

import support.util.{stringTrim, joinWith}
import string.{words}
import support.timer.{perfEnabled, now, emitPhase}
import driver.loader.{entrySearchRoots, findProjectRootOrSelf, readForeignLibs}
import support.path.{dirOf, chopExt, joinPath}
import frontend.parser.{parseResult}
import frontend.parse_cache.{notePreludeParse}
import driver.diagnostics.{parseErrDiag, ppDiagCliSrc}

-- A build either succeeds (writing the binary) or fails with a message.
public export data BuildResult = BuildOk String | BuildErr String

-- Backend target: TNative = the LLVM/clang native binary (default); TWasm =
-- WasmGC via the wasm_emit entry + wasm-tools assemble/validate.
public export data BuildTarget = TNative | TWasm

-- Append an informational suffix (e.g. a "kept IR" note) to a BuildResult's
-- message, whichever arm it is — so a --keep-ir note is visible whether the
-- rest of the build (clang / wasm-tools) went on to succeed or fail.
appendNote : String -> BuildResult -> BuildResult
appendNote note (BuildOk m) = BuildOk (m ++ note)
appendNote note (BuildErr m) = BuildErr (m ++ note)

-- ---- environment / asset resolution ----

export
envOr : String -> String -> <IO> String
-- Intentional cross-file duplicate of the same helper in lsp_harness_main.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
envOr name dflt = match getEnv name
  Some v => if v == "" then dflt else v
  None => dflt

-- ---- exe-relative install-layout defaults (D1, DISTRIBUTION-DESIGN.md §4) ----
-- A relocated `medaka` binary can't assume it's running inside this repo, so
-- when MEDAKA_ROOT/MEDAKA_EMITTER are unset we derive them from the running
-- executable's OWN location rather than defaulting to "." (cwd) / "" (broken
-- `medaka run <emitter>` fallback).  The layout `make medaka` already produces —
-- `./medaka`, `./medaka_emitter`, and `stdlib/` all siblings at the repo root —
-- IS this default layout, so the in-repo dev build keeps working with no env
-- vars set: exeDir is the repo root, exactly what MEDAKA_ROOT needs to be.  An
-- explicit env var always wins (envOr only falls back to these when unset).
export
exeDir : <IO> String
exeDir = dirOf (executablePath ())

export
defaultMedakaRoot : <IO> String
defaultMedakaRoot = exeDir

export
defaultMedakaEmitter : <IO> String
defaultMedakaEmitter = joinPath exeDir "medaka_emitter"

-- Reads a stdlib prelude file (stdlib/runtime.mdk or stdlib/core.mdk) and, on
-- failure, wraps the bare strerror `readFile` returns (e.g. "No such file or
-- directory") in an ACTIONABLE message naming the resolved path and the fix —
-- same style as the MEDAKA_WASM_EMITTER hint below.  Without this, a relocated
-- `medaka` binary with no exe-relative stdlib/ sibling (and no MEDAKA_ROOT set)
-- fails every subcommand with a bare, contextless "No such file or directory"
-- (#132) — the structural exe-relative/MEDAKA_ROOT lookup (above) is correct,
-- but a MISS gave the user nothing to act on.  Prelude reads only — a missing
-- USER file should keep reporting its own bare "No such file or directory:
-- <path>", which is already unambiguous.
-- A parse error in the prelude (stdlib/core.mdk or stdlib/runtime.mdk) used to
-- surface as a bare unlocated `runtime error [E-PANIC]: parse error`: every
-- caller here parses the returned source with the PANICKING `parse`, so a syntax
-- error anywhere in the implicit prelude made EVERY command die identically with
-- no file, no line, no mention of the prelude — the compiler looked "globally,
-- inexplicably broken" to whoever was editing core.mdk (#510).  Since every
-- command reads the prelude through THIS one function and already renders the
-- `Err` and exits nonzero, validate the parse HERE (via the non-panicking
-- `parseResult`) and, on failure, return the SAME located `file:L:C:` diagnostic
-- `medaka check` prints for a user file — rendered through the shared
-- `parseErrDiag`/`ppDiagCliSrc` machinery — plus a context line naming it as the
-- prelude.  Same shape as the #892 fix for `medaka test`.
--
-- #2234: that validating parse is no longer EXTRA.  Its decls used to be
-- discarded (`Ok _ => Ok src`) and the source re-parsed three more times
-- downstream — 54.15% of a hello-world `medaka check` went on parsing the two
-- prelude files four times each.  The `Ok` payload is now published to the
-- prelude parse memo (`frontend/parse_cache.mdk`), so this validation IS the one
-- parse and every downstream `parsePrelude` hits it.  Keep the return type as the
-- SOURCE text: eleven call-site pairs and the whole `analyzeFrom` surface consume
-- it as a String, and the memo reaches them without re-signing any of them.
export
readPreludeFile : String -> <IO> Result String String
readPreludeFile path = match readFile path
  Err e => Err "error: cannot read the stdlib prelude at \"\{path}\" (\{e})\n  set MEDAKA_ROOT to your medaka repo/install root, run from the project root, or place stdlib/ next to the medaka binary"
  Ok src => match parseResult src
    Err pe => Err "\{ppDiagCliSrc src path (parseErrDiag path pe)}\n  (while loading the implicit prelude)"
    Ok decls =>
      let _ = notePreludeParse src decls
      Ok src

-- ---- the trailing-Unit auto-print trim ----
-- The interpreter auto-prints main's Unit as a trailing "()\n"; the emitter's
-- IR is captured via subprocess stdout, so strip a trailing "()\n" if present
-- (mirrors strip_trailing_unit in build_cmd.ml).
stripTrailingUnit : String -> String
stripTrailingUnit s =
  let n = stringLength s
  if n >= 3 && stringSlice (n - 3) n s == "()\n" then
    stringSlice 0 (n - 3) s
  else
    s

-- ---- per-invocation scratch directory ----
-- SCRATCH-PATH INVARIANT.  Every temp file this driver stages — the emitted
-- .ll / .wat, and the bare-`-lgc` probe source + probe binary — lives inside ONE
-- directory created by `mktemp -d`, unique to this `medaka build` process, and
-- removed before the driver returns.
--
-- This is the only scheme that is actually collision-proof.  Two earlier ones
-- were not:
--   * keying the IR path on the OUTPUT BASENAME (`/tmp/medaka_build_<base>.ll`)
--     is only *basename*-safe.  /tmp is GLOBAL: two concurrent builds of
--     DIFFERENT inputs that both write `-o <somedir>/out` — different worktrees,
--     different sessions, different repos — collided on one
--     /tmp/medaka_build_out.ll and linked each other's IR.  The failure was not
--     a crash but a stable-looking WRONG binary.
--   * the gc probe paths (/tmp/medaka_build_gcprobe.{c,out}) were FIXED — not
--     uniquified at all.
-- Even keying on the ABSOLUTE output path would not suffice: a rebuild racing
-- itself writes the same output path.  mktemp -d allocates the directory
-- atomically, so uniqueness depends on nothing but the process.  The 6-X
-- template is accepted by both GNU and BSD mktemp (dual-platform).
export
makeTempDir : Unit -> <IO> Result String String
makeTempDir _ = match runCommand "mktemp" ["-d", "/tmp/medaka_build_XXXXXX"]
  Err e => Err e
  Ok (0, out, _) =>
    let dir = stringTrim out
    if dir == "" then Err "mktemp -d printed no path" else Ok dir
  Ok (_, _, mtErr) =>
    let msg = stringTrim mtErr
    Err (if msg == "" then "mktemp -d failed" else msg)

-- Best-effort unlink of every entry the build staged in the scratch dir.  The
-- driver only ever writes flat files there, so removeFile suffices.
removeEntries : String -> List String -> <IO> Unit
removeEntries _ [] = ()
removeEntries dir (n::rest) =
  let _ = removeFile (joinPath dir n)
  removeEntries dir rest

-- Tear the scratch dir down so a build leaks nothing into /tmp.  Every Result is
-- discarded on purpose: a cleanup failure must never fail an otherwise-good build.
export
cleanupTempDir : String -> <IO> Unit
cleanupTempDir dir = match listDir dir
  Err _ => ()
  Ok entries =>
    let _ = removeEntries dir entries
    let _ = removeDir dir
    ()

-- ---- startup sweep of leaked scratch dirs (issue #97) ----
-- A build stages scratch under makeTempDir's /tmp/medaka_build_* dir and removes
-- it on the NORMAL exit path (cleanupTempDir).  A build KILLED before that runs —
-- `timeout`, Ctrl-C, OOM, SIGKILL — leaks its dir.  Over a long multi-agent
-- session these accumulated to 96% of a 16 GB RAM-backed tmpfs (1,041 dirs).  A
-- signal trap cannot cover SIGKILL, so instead every build, at startup, sweeps
-- dirs that are provably NOT in use BEFORE creating its own (issue #97 option 2).
--
-- CONCURRENCY SAFETY is the hard constraint: this is the exact file whose
-- per-process-dir design fixed a 19/20 silent-WRONG-binary race, and a sweep that
-- deletes a LIVE build's dir reintroduces it.  The guard is AGE: a dir is removed
-- only if its mtime is older than 6 HOURS — far beyond any real build (seconds to
-- minutes).  A just-created or in-progress dir has a recent mtime, so a
-- concurrently-starting build (parallel worktrees on the same box) is never
-- swept — the age gate IS the concurrency guard.  The predicate is evaluated by
-- `find -mmin +360`, atomic w.r.t. the filesystem and supported by BOTH GNU find
-- (Linux) and BSD find (macOS), so no "now" primitive is needed and the module
-- stays self-contained.
--
-- BEST-EFFORT: the sweep must never fail or slow a build.  Every failure mode —
-- `find` absent, a foreign user's dir we cannot remove, a dir another process
-- removed mid-sweep — is swallowed (the Err arm is (), and cleanupTempDir already
-- discards every Result).  A leaked dir only ever holds the flat files a build
-- stages (program.ll, the gc probe, a stub .mdk / obj), so cleanupTempDir's
-- listDir + flat removeFile + removeDir tears it down exactly as for a live build.
sweepStaleTempDirs : Unit -> <IO> Unit
sweepStaleTempDirs _ =
  let findArgs = [
    "/tmp",
    "-maxdepth",
    "1",
    "-type",
    "d",
    "-name",
    "medaka_build_*",
    "-mmin",
    "+360",
  ]
  match runCommand "find" findArgs
    Ok (_, out, _) => sweepEachStale (words out)
    Err _ => ()

sweepEachStale : List String -> <IO> Unit
sweepEachStale [] = ()
sweepEachStale (d::rest) =
  let _ = cleanupTempDir d
  sweepEachStale rest

-- ---- Boehm GC flag detection (pkg-config → brew → bare -lgc) ----
-- Returns Some (cflags, libs) or None.  tmpDir is the caller's per-invocation
-- scratch dir (the bare-lgc probe is staged inside it).
detectGC : String -> String -> <IO> Option (List String, List String)
detectGC cc tmpDir = match runCommand "pkg-config" ["--exists", "bdw-gc"]
  Ok (0, _, _) =>
    let cflags = gcQuery "pkg-config" ["--cflags", "bdw-gc"]
    let libs = gcQuery "pkg-config" ["--libs", "bdw-gc"]
    Some (words cflags, words libs)
  _ => detectGCBrew cc tmpDir

gcQuery : String -> List String -> <IO> String
gcQuery prog args = match runCommand prog args
  Ok (_, out, _) => stringTrim out
  Err _ => ""

detectGCBrew : String -> String -> <IO> Option (List String, List String)
detectGCBrew cc tmpDir = match runCommand "brew" ["--prefix", "bdw-gc"]
  Ok (0, out, _) =>
    let prefix = stringTrim out
    if prefix /= "" && fileExists (joinPath prefix "include/gc.h") then
      Some (
        ["-I" ++ joinPath prefix "include"],
        ["-L" ++ joinPath prefix "lib", "-lgc"],
      )
    else
      detectGCBare cc tmpDir
  _ => detectGCBare cc tmpDir

-- Bare -lgc probe: compile a trivial gc.h program from a temp source.  Both the
-- probe source and its output binary go in the per-invocation scratch dir — they
-- used to be fixed /tmp paths, which two concurrent builds raced on.
detectGCBare : String -> String -> <IO> Option (List String, List String)
detectGCBare cc tmpDir =
  let probe = joinPath tmpDir "gcprobe.c"
  let probeOut = joinPath tmpDir "gcprobe.out"
  let _ = writeFile probe "#include <gc.h>\nint main(void){return 0;}\n"
  match runCommand cc [probe, "-lgc", "-o", probeOut]
    Ok (0, _, _) => Some ([], ["-lgc"])
    _ => None

-- ---- section-level dead-code-elim flags (issue #120) ----
-- -ffunction-sections/-fdata-sections put each fn/global in its own section so
-- the LINKER's real relocation graph (not source-level analysis) decides what
-- survives: source DCE (compiler/ir/dce.mdk) cannot prune an impl — dict-
-- passing means pruning one could be a silent miscompile, so it keeps every
-- DImpl/DInterface WHOLE — but the linker sees the actual call/dict
-- relocations and recovers exactly what source DCE is obliged to leave
-- behind (measured 77% smaller on a sample fixture: 192,336 -> 44,088 bytes,
-- byte-identical program output). Compile flags are identical on both
-- toolchains (GNU as and Apple clang both accept them).
gcSectionsCflags : List String
gcSectionsCflags = ["-ffunction-sections", "-fdata-sections"]

-- The matching LINKER flag differs by platform: GNU ld/gold/lld (Linux) take
-- `--gc-sections`; macOS's ld64 has no such flag and uses `-dead_strip`
-- instead. Detected via `uname -s` (rather than hardcoded) so this stays
-- correct on the Mac smoke-test machine — the AGENTS.md dual-platform
-- invariant. Falls back to the GNU flag if `uname` itself is unavailable
-- (matches every other best-effort probe in this file).
gcSectionsLinkFlag : Unit -> <IO> String
gcSectionsLinkFlag _ = match runCommand "uname" ["-s"]
  Ok (0, out, _) =>
    if stringTrim out == "Darwin" then
      "-Wl,-dead_strip"
    else
      "-Wl,--gc-sections"
  _ => "-Wl,--gc-sections"

-- ---- keep-IR (--keep-ir / MEDAKA_KEEP_IR) ----
-- Normally the emitted IR lives ONLY inside the per-process scratch dir
-- (makeTempDir) and is gone the instant the build returns — which is exactly
-- the problem for the project's #1 bug class ("check green / build silently
-- wrong"): the IR that actually produced the binary is the evidence, and by
-- default we destroy it.  `--keep-ir` (or the env var, for a build shelled out
-- by something else, e.g. a test harness) copies that IR to a PREDICTABLE
-- path next to the output binary — outPath ++ ".ll" (native) / ".wat" (wasm)
-- — and reports the path in the build's own result message.  Purely additive:
-- with neither the flag nor the env var set, effectiveKeepIr is False and
-- nothing about the scratch-dir lifecycle changes.
--
-- WHY "next to the output binary" is safe under concurrency, even though two
-- DIFFERENT builds sharing one `-o` is the exact shape that broke IR-path
-- uniqueness before (see makeTempDir's doc comment): here the compile itself
-- never reads this path — the kept file is a copy of IR that a build already
-- finished reading out of ITS OWN private tmpDir, written purely for the
-- human afterward.  So a foreign build can never be compiled from another
-- build's IR (the actual historical failure mode — a stable-looking WRONG
-- binary).  What remains is the ordinary last-write-wins race on `outPath`
-- itself when two builds target the same output path concurrently — a
-- pre-existing, accepted property of sharing an output path (the binary at
-- outPath already has it) — the kept-IR file just shares that same, already-
-- understood race, not a new one.
effectiveKeepIr : Bool -> <IO> Bool
effectiveKeepIr cliFlag = cliFlag || envOr "MEDAKA_KEEP_IR" "" /= ""

-- Best-effort: a kept-IR write failure must never fail an otherwise-good
-- build, so its Result is folded into an informational note either way.
keepIrNote : String -> String -> <IO> String
keepIrNote path contents = match writeFile path contents
  Ok _ => "\nkept IR: " ++ path
  Err e => "\nwarning: could not keep IR at \{path}: " ++ e

-- #1693: on a FAILED emitter run, its stderr is already folded into the
-- BuildErr message above (`\{emitErr}`). On SUCCESS it used to be dropped on
-- the floor — the only way to see it was to bypass `medaka build` entirely
-- and shell out to `./medaka_emitter` directly. Fold it into the success
-- note instead, so a clean build still surfaces whatever the emitter wrote
-- along the way (progress/diagnostic chatter is expected to be low-volume).
emitStderrNote : String -> String
emitStderrNote emitErr =
  if stringLength emitErr == 0 then
    ""
  else
    "\n" ++ emitErr

-- ---- the build pipeline ----
-- root  = repo root (assets live under it)
-- medaka = path to the medaka exe (for the emit shell-out)
-- cc    = C compiler
-- target = TNative (LLVM/clang) | TWasm (WasmGC + wasm-tools)
-- inputAbs = absolute path of the user .mdk entry
-- outPath  = output binary path
-- keepIrCli = True iff `--keep-ir` was passed on the command line (OR'd with
--             MEDAKA_KEEP_IR inside effectiveKeepIr)
export
runBuild : String -> String -> String -> BuildTarget -> String -> String -> Bool -> <IO> BuildResult
runBuild root medaka cc TNative inputAbs outPath keepIrCli =
  let _ = sweepStaleTempDirs ()
  runBuildNative root medaka cc inputAbs outPath keepIrCli
runBuild root medaka cc TWasm inputAbs outPath keepIrCli =
  let _ = sweepStaleTempDirs ()
  runBuildWasm root medaka inputAbs outPath keepIrCli

-- ---- native (LLVM/clang) target — the original path ----
-- Wrapper: allocate the per-invocation scratch dir (see makeTempDir), run the
-- build inside it, then tear it down whatever the outcome.  `res` is bound (and
-- so fully forced — Medaka is strict) BEFORE cleanupTempDir runs, so the .ll is
-- still on disk while clang reads it.
runBuildNative : String -> String -> String -> String -> String -> Bool -> <IO> BuildResult
runBuildNative root medaka cc inputAbs outPath keepIrCli = match makeTempDir ()
  Err e =>
    BuildErr "error: could not create a scratch directory for the build: \{e}"
  Ok tmpDir =>
    let res = runBuildNativeIn root medaka cc inputAbs outPath tmpDir keepIrCli
    let _ = cleanupTempDir tmpDir
    res

-- Thin compatibility wrapper: every existing caller wants the plain P0-13 root
-- set with nothing extra appended. Delegates to runBuildNativeRoots with
-- extraRoots = [] — byte-identical behavior to the pre-Stage-0 function.
runBuildNativeIn : String -> String -> String -> String -> String -> String -> Bool -> <IO> BuildResult
runBuildNativeIn root medaka cc inputAbs outPath tmpDir keepIrCli =
  runBuildNativeRoots root medaka cc inputAbs outPath tmpDir keepIrCli []

-- Like runBuildNativeIn, but callers may supply extraRoots — additional
-- search roots appended AFTER the P0-13 inputRoots set. Needed by a caller
-- whose entry file lives in a mktemp -d scratch dir, where entrySearchRoots
-- (walking up from the entry's own dir) resolves nothing useful: a future
-- native test-execution engine builds a synthesized doctest entry there and
-- must still see the real project's import roots.
export
runBuildNativeRoots : String -> String -> String -> String -> String -> String -> Bool -> List String -> <IO> BuildResult
runBuildNativeRoots root medaka cc inputAbs outPath tmpDir keepIrCli extraRoots =
  let emitter = joinPath root "compiler/entries/llvm_emit_modules_main.mdk"
  let runtimeP = joinPath root "stdlib/runtime.mdk"
  let preludeP = joinPath root "stdlib/core.mdk"
  let rtC = joinPath root "runtime/medaka_rt.c"
  let compilerDir = joinPath root "compiler"
  let stdlibDir = joinPath root "stdlib"
  -- P0-13: entrySearchRoots gives BOTH the entry's own dir (resolves a bare
  -- sibling import next to the entry, e.g. `src/main.mdk` importing
  -- `src/helper.mdk`'s `helper`) and the project root found by walking up from
  -- there (resolves a dotted cross-package import rooted at the project dir) —
  -- see the loader.mdk doc comment. A single `findProjectRoot` root here used to
  -- swallow the sibling-import case whenever a `medaka.toml` sat above the
  -- entry's own directory.
  let inputRoots = entrySearchRoots (dirOf inputAbs) ++ extraRoots
  -- Stage the IR inside THIS invocation's private scratch dir (makeTempDir).  It
  -- used to be /tmp/medaka_build_<output basename>.ll, which is only
  -- basename-unique in a GLOBAL directory — concurrent builds writing the same
  -- output basename (very common: `-o <tmpdir>/out`) overwrote each other's IR.
  let llPath = joinPath tmpDir "program.ll"
  let emitArgsBase = [runtimeP, preludeP, inputAbs] ++ inputRoots ++ [compilerDir, stdlibDir]
  let emitter2 = envOr "MEDAKA_EMITTER" defaultMedakaEmitter
  let useNative = emitter2 /= ""
  let emitProg0 = if useNative then emitter2 else medaka
  let emitArgs0 = if useNative then
    emitArgsBase
  else
    "run" :: emitter::emitArgsBase
  -- CI FAST PATH (MEDAKA_PRELUDE_OBJ, issue #118) — the prelude half.  When a
  -- prebuilt prelude.o is on offer, tell the emitter to emit THIS PROGRAM ONLY
  -- (declaring what prelude.o defines): 88% of a small program's IR is prelude, and
  -- clang -O2 re-optimises all of it on every build.  See preludeObjOf below.
  let (emitProg, emitArgs) = if preludeObjOf () == "" then
    (emitProg0, emitArgs0)
  else
    withEmitHalf "program" emitProg0 emitArgs0
  -- `[perf] emit-ir`: the emitter subprocess alone.  The CLI's single `emit` row
  -- (medaka_cli.mdk) covers this WHOLE function and is deliberately kept as the
  -- total; these sub-rows decompose it (emit-ir + rt-obj + clang) so a slow build
  -- names its own culprit instead of reporting one opaque 1.4 s number.
  let perfOn = perfEnabled ()
  let tEmit0 = now ()
  let emitRes = runCommand emitProg emitArgs
  let tEmit1 = now ()
  let _ = emitPhase perfOn "emit-ir" (tEmit1 - tEmit0) inputAbs
  match emitRes
    Err e =>
      BuildErr "error: could not run emitter (\{emitProg}): \{e}"
    Ok (code, irRaw, emitErr) => if code /= 0 then BuildErr "error: emitter failed compiling \{inputAbs}\n\{emitErr}"
    else
      let ir = stripTrailingUnit irRaw
      if stringLength ir == 0 then BuildErr "error: emitter produced empty IR for \{inputAbs}\n\{emitErr}"
      else match writeFile llPath ir
        Err e => BuildErr ("error: could not write IR: " ++ e)
        Ok _ =>
          -- --keep-ir / MEDAKA_KEEP_IR: copy the IR to a predictable path next
          -- to the output binary AFTER clangLink returns (success or failure —
          -- a clang failure is exactly the case where seeing the IR matters
          -- most), not before.  This is deliberate, not incidental: two
          -- concurrent builds of DIFFERENT programs sharing one `-o` each run
          -- an independent last-write-wins race on outPath (pre-existing,
          -- inherent to sharing an output path) AND, if we copied the .ll
          -- first, a SEPARATE independent race on outPath++".ll" — the two
          -- races can pick different "winners", pairing build A's binary with
          -- build B's kept IR (silently misleading — measured empirically:
          -- ~1/3 of trials crossed when the .ll copy ran before clangLink).
          -- Writing the copy immediately after clangLink returns collapses the
          -- two races to nearly the same instant in each process's timeline,
          -- so whichever build's clang finishes last is also the one most
          -- likely to finish its .ll copy last. This narrows, but for a
          -- same-`-o` race cannot fully eliminate, the crossing window — see
          -- the concurrency note on effectiveKeepIr for why builds to
          -- DISTINCT `-o` paths (the normal, sane usage) have NO such race at
          -- all.
          -- Foreign libraries declared by the PROJECT's medaka.toml (not `root`,
          -- which is the medaka install root that supplies runtime.mdk/core.mdk):
          -- the project root is found by walking up from the entry, exactly as
          -- readDeps' callers in loader.mdk do.
          let ffiRoot = findProjectRootOrSelf (dirOf inputAbs)
          let res = clangLink cc rtC llPath outPath inputAbs tmpDir ffiRoot (readForeignLibs ffiRoot)
          let note = (if effectiveKeepIr keepIrCli then keepIrNote (outPath ++ ".ll") ir else "") ++ emitStderrNote emitErr
          appendNote note res

-- ---- wasm (WasmGC + wasm-tools) target ----
-- Structurally identical to runBuildNative: run the emitter (here the WasmGC
-- modules entry) via a fresh subprocess, capture its WAT on stdout, then assemble
-- with `wasm-tools parse` (the clang analogue) and `wasm-tools validate` (GC
-- validation, on by default) instead of clang.
--
-- EMITTER BINARY.  Like the LLVM path, the emitter must be a COMPILED binary, not
-- `medaka run <entry>`: the entry's `main = match args ()` needs the `args` runtime
-- extern, which exists in the native runtime but NOT in the native interpreter's
-- run mode — so `medaka run <emitter>` fails at resolve (`unbound identifier:
-- args`) for the LLVM entry too.  The LLVM path sidesteps this via the compiled
-- MEDAKA_EMITTER binary, which defaults to `<exeDir>/medaka_emitter` (a self-
-- locating default — `make medaka` always builds it alongside `medaka`, so the
-- LLVM path needs no env var in the common case).  The wasm peer has NO such
-- self-locating default (there is no fixed post-build location for the wasm
-- emitter binary), so MEDAKA_WASM_EMITTER MUST be set — build one with
-- `test/wasm/build_wasm_oracle.sh` (produces test/bin/wasm_emit_modules_main).
--
-- ⚠️ T-22 (2026-07-14): this used to fall back to `medaka run <entry>` when unset,
-- on the theory that the failure would be "surfaced clearly" — it was not. `medaka`
-- here is whatever `envOr "MEDAKA" "medaka"` resolves to (a bare PATH-relative name
-- by default, NOT this process's own exeDir), so the fallback typically shells a
-- `medaka` that plain isn't found on PATH — `runCommand` reports that as a bare
-- "No such file or directory", which names neither the missing env var nor the
-- fix. Three separate agents lost time to this. No in-repo caller ever relied on
-- the fallback actually working (every gate that drives --target wasm sets
-- MEDAKA_WASM_EMITTER itself), so it is now an explicit, actionable error instead
-- of a silent, broken code path — the same treatment probeWasmTools already gets
-- below for missing wasm-tools.
-- Args mirror the LLVM root set: the COMPILED binary takes positional
-- <runtime> <core> <entry> <inputDir> <compiler> <stdlib> (the wasm entry takes
-- any number of roots after the entry).
runBuildWasm : String -> String -> String -> String -> Bool -> <IO> BuildResult
runBuildWasm root medaka inputAbs outPath keepIrCli = match makeTempDir ()
  Err e =>
    BuildErr "error: could not create a scratch directory for the build: \{e}"
  Ok tmpDir =>
    let res = runBuildWasmIn root medaka inputAbs outPath tmpDir keepIrCli
    let _ = cleanupTempDir tmpDir
    res

runBuildWasmIn : String -> String -> String -> String -> String -> Bool -> <IO> BuildResult
runBuildWasmIn root medaka inputAbs outPath tmpDir keepIrCli =
  let runtimeP = joinPath root "stdlib/runtime.mdk"
  let preludeP = joinPath root "stdlib/core.mdk"
  let compilerDir = joinPath root "compiler"
  let stdlibDir = joinPath root "stdlib"
  -- P0-13: see the comment on runBuildNative's inputRoots — same fix.
  let inputRoots = entrySearchRoots (dirOf inputAbs)
  -- Same scratch-path invariant as the native path: the WAT is staged in THIS
  -- invocation's private mktemp dir, not at a globally-shared
  -- /tmp/medaka_build_<output basename>.wat that a concurrent build can clobber.
  let watPath = joinPath tmpDir "program.wat"
  let emitArgsBase = [runtimeP, preludeP, inputAbs] ++ inputRoots ++ [compilerDir, stdlibDir]
  let wasmEmitter = envOr "MEDAKA_WASM_EMITTER" ""
  -- Surface a missing/unset/mistyped MEDAKA_WASM_EMITTER as an actionable error
  -- here; without this, runCommand fails with a bare "No such file or directory"
  -- that names neither the variable nor the fix.
  if wasmEmitter == "" then
    BuildErr "error: --target wasm needs a compiled wasm emitter — set MEDAKA_WASM_EMITTER to its path\n  build one with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)"
  else if not (fileExists wasmEmitter) then
    BuildErr "error: MEDAKA_WASM_EMITTER points to a missing binary: \{wasmEmitter}\n  build it with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)"
  else match probeWasmTools ()
    None => BuildErr "error: wasm-tools not found on PATH — install wasm-tools (cargo install wasm-tools or brew install wasm-tools) for --target wasm"
    Some _ => match runCommand wasmEmitter emitArgsBase
      Err e => BuildErr "error: could not run wasm emitter (\{wasmEmitter}): \{e}"
      Ok (code, watRaw, emitErr) => if code /= 0 then BuildErr "error: wasm emitter failed compiling \{inputAbs}\n\{emitErr}"
      else
        let wat = stripTrailingUnit watRaw
        if stringLength wat == 0 then BuildErr "error: wasm emitter produced empty WAT for \{inputAbs}\n\{emitErr}"
        else match writeFile watPath wat
          Err e => BuildErr ("error: could not write WAT: " ++ e)
          Ok _ =>
            -- Same --keep-ir handling as the native path (.wat instead of
            -- .ll), including the AFTER-assemble ordering — see the comment
            -- on the native path's runBuildNativeIn for why.
            let res = wasmAssemble watPath outPath inputAbs
            let note = (if effectiveKeepIr keepIrCli then keepIrNote (outPath ++ ".wat") wat else "") ++ emitStderrNote emitErr
            appendNote note res

-- Probe `wasm-tools` up front (the wasm analogue of the implicit clang
-- requirement).  `wasm-tools --version` exits 0 iff the tool is reachable.
probeWasmTools : Unit -> <IO> Option Unit
probeWasmTools _ = match runCommand "wasm-tools" ["--version"]
  Ok (0, _, _) => Some ()
  _ => None

-- STEP 2 (wasm): assemble the WAT to a .wasm with `wasm-tools parse`, then GC-
-- validate it with `wasm-tools validate`.  Surfaces each tool's own stderr on
-- failure.  `--features=all` matches the gate scripts' validate (GC + tail-call).
-- Once validated, strip the debug `name` custom section with `wasm-tools strip
-- --all` — it is pure debug info (31-42% of emitted bytes, #2377) and this is
-- the one place a user-facing `.wasm` gets produced (`runBuildWasmIn`, the only
-- caller). Validating BEFORE stripping keeps validate's error messages meaningful
-- against the artifact as assembled; gate-consumed WAT/`wasm-tools print` output
-- never goes through this function, so names stay intact there.
wasmAssemble : String -> String -> String -> <IO> BuildResult
wasmAssemble watPath outPath inputAbs = match runCommand "wasm-tools" ["parse", watPath, "-o", outPath]
  Err e => BuildErr ("error: could not run wasm-tools parse: " ++ e)
  Ok (0, _, _) => match runCommand "wasm-tools" ["validate", "--features=all", outPath]
    Err e => BuildErr ("error: could not run wasm-tools validate: " ++ e)
    Ok (0, _, _) => match runCommand "wasm-tools" ["strip", "--all", outPath, "-o", outPath]
      Err e => BuildErr ("error: could not run wasm-tools strip: " ++ e)
      Ok (0, _, _) => BuildOk "built \{inputAbs} -> \{outPath}"
      Ok (_, _, stripErr) =>
        BuildErr "error: wasm-tools strip failed on \{outPath}\n\{stripErr}"
    Ok (_, _, valErr) =>
      BuildErr "error: wasm-tools validate rejected \{outPath}\n\{valErr}"
  Ok (_, _, parseErr) => BuildErr "error: wasm-tools parse failed assembling \{inputAbs}\n\{parseErr}"
-- EMIT STEP.  Two paths, selected by the MEDAKA_EMITTER env var:
--   * set   → invoke that NATIVE EMITTER BINARY directly (OCaml-free path — the
--             clang(seed) binary from test/bootstrap_from_seed.sh).  Args are the
--             emitter's positional inputs WITHOUT the "run <emitter>" prefix.
--   * unset → fall back to a fresh `medaka run <emitter> …` subprocess (the
--             original OCaml-interpreter path; nothing regresses).
-- Both receive identical <runtime> <prelude> <input> <inputDir> <compiler> <stdlib>
-- args and produce identical IR (the native emitter is the clang-compiled seed,
-- byte-fixpoint with the interpreter — selfcompile_build_fixpoint.sh C3a/C3b).

-- STEP 1: emit LLVM IR via a FRESH subprocess (Ref-state isolation).
-- Roots: inputDir (user modules shadow stdlib), compiler, stdlib — mirrors
-- the loader's root-ordered search and build_cmd.ml's emit_argv.

-- Optimization level is overridable via MEDAKA_CLANG_OPT (default -O2). The
-- oracle build (test/build_oracles.sh) sets a lower level: those are throwaway
-- test binaries where clang -O2 (~half the per-build wall time) buys little
-- runtime on the small gate fixtures they process.  A single reader so the
-- link path and the `--emit-rt-obj` precompile path can never drift on the opt
-- level (a mismatch would make the prebuilt object subtly incompatible).
clangOptFlag : <IO> String
clangOptFlag =
  let optFlagRaw = envOr "MEDAKA_CLANG_OPT" "-O2"
  if optFlagRaw == "" then "-O2" else optFlagRaw

-- STEP 2: clang the IR + C runtime + Boehm GC into a native binary.
--
-- FOREIGN LIBRARIES (medaka.toml `[foreign-libraries]`, loader.readForeignLibs).
-- Declared libraries are PROBED first, then threaded onto the link as
-- `-L<dir>`/`-l<name>` immediately after the object inputs (so they can resolve
-- the objects' undefined symbols) and before the GC libs.  With NO declared
-- libraries the flag list is `[]` and the probe is skipped outright, so the
-- clang argv is byte-identical to the pre-FFI one.
clangLink : String -> String -> String -> String -> String -> String -> String -> List (String, String) -> <IO> BuildResult
clangLink cc rtC llPath outPath inputAbs tmpDir projRoot libs =
  let libErr = foreignLibErr cc tmpDir projRoot libs
  if libErr /= "" then
    BuildErr libErr
  else
    clangLinkGo cc rtC llPath outPath inputAbs tmpDir (libLinkFlags libs)

-- `-L<dir>`/`-l<name>` for each declared library, in declaration order.  A
-- library with no search directory contributes `-l<name>` alone.
libLinkFlags : List (String, String) -> List String
libLinkFlags [] = []
libLinkFlags ((name, dir)::rest) =
  let here = if dir == "" then ["-l\{name}"] else ["-L\{dir}", "-l\{name}"]
  here ++ libLinkFlags rest

-- Pre-link existence probe for each declared foreign library; "" when all
-- resolve.  WHY A PROBE AND NOT STDERR-SCRAPING: `ld: library not found for
-- -lfoo` is one of several per-platform, per-linker spellings, and by the time
-- it appears it is mixed into whatever else the real link reported — matching
-- on it is a guess about someone else's wording.  WHY NOT AN fileExists SWEEP
-- of a guessed `lib<name>.{so,dylib,a}` under a guessed set of directories: the
-- linker's own search order (sysroot, -L, default dirs, per-distro multiarch
-- paths) is not reconstructible from Medaka, so such a check would report
-- "missing" for libraries that link fine.  Asking the ACTUAL linker to link an
-- empty `main` against exactly this one library answers the exact question the
-- real link will ask, deterministically, with no wording dependency — and the
-- diagnostic below is then ours, not clang's.
--
-- Cost: one trivial clang invocation per DECLARED library.  A project with no
-- `[foreign-libraries]` section pays nothing (the [] clause returns before the
-- probe source is even written).
foreignLibErr : String -> String -> String -> List (String, String) -> <IO> String
foreignLibErr _ _ _ [] = ""
foreignLibErr cc tmpDir projRoot libs =
  let probeC = joinPath tmpDir "ffi_lib_probe.c"
  match writeFile probeC "int main(void) { return 0; }\n"
    Err e => "error: could not write the foreign-library probe source: \{e}"
    Ok _ => foreignLibErrGo cc tmpDir projRoot probeC libs

foreignLibErrGo : String -> String -> String -> String -> List (String, String) -> <IO> String
foreignLibErrGo _ _ _ _ [] = ""
foreignLibErrGo cc tmpDir projRoot probeC ((name, dir)::rest) =
  let probeOut = joinPath tmpDir "ffi_lib_probe.out"
  match runCommand cc ([probeC, "-o", probeOut] ++ libLinkFlags [(name, dir)])
    Err e => "error: could not run clang (\{cc}) to check foreign library '\{name}': \{e}"
    Ok (0, _, _) => foreignLibErrGo cc tmpDir projRoot probeC rest
    Ok (_, _, _) => missingLibMsg projRoot name dir

-- The missing-library diagnostic: names the library, the manifest KEY that
-- declared it, the file that key lives in, where we looked, and the edit that
-- fixes it — instead of clang's bare `ld: library not found for -lfoo`.
missingLibMsg : String -> String -> String -> String
missingLibMsg projRoot name dir =
  let searched = if dir == "" then
    "the linker's default search path"
  else
    "\{dir}, nor on the linker's default search path"
  stringConcat
    [
      "error [B-FFI-LIB-NOT-FOUND]: foreign library '",
      name,
      "' was not found in ",
      searched,
      "\n",
      "  declared by the key '",
      name,
      "' under [foreign-libraries] in ",
      projRoot,
      "/medaka.toml\n",
      "  install the library, or point that key at the directory holding it: ",
      name,
      " = \"vendor/lib\"",
    ]

-- ---- the automatic C-runtime object cache (#133, epic #2036 G1) ------------
-- MEASURED attribution of hello-world's ~1.5 s `medaka build` (this tree, this
-- box; the `[perf]` sub-rows below report it live):
--   typecheck            0.16 s
--   emit-ir (subprocess) 0.12 s
--   clang, of which:     1.33 s
--       runtime/medaka_rt.c -> object   0.76 s   <-- THIS, 50% of the whole build
--       program+prelude IR  -> object   0.51 s
--       link                            0.04 s
-- medaka_rt.c is a FIXED file: byte-for-byte the same object on every build of
-- every program on the machine.  Recompiling it per build is pure waste, and
-- because clang already treats the .c and the .ll as SEPARATE translation units
-- (no LTO on this link line), substituting a prebuilt object changes nothing
-- about the emitted program — proven byte-identical by
-- test/diff_compiler_rt_obj.sh, and re-measured over test/bench_fixtures/*:
-- 19/19 fixtures byte-identical binaries, runtime within noise.
--
-- ⚠️ WHY ONLY THE RUNTIME, AND NOT THE PRELUDE.  The sibling MEDAKA_PRELUDE_OBJ
-- fast path is deliberately NOT auto-enabled here.  Splitting the prelude into
-- its own object costs cross-module inlining, and that cost is real and large —
-- measured over test/bench_fixtures/* with prelude.o linked instead of inlined:
--   dispatch  23,568 -> 28,424 bytes (+20.6%), runtime 0.20 -> 0.34 s (+70%)
--   fib       runtime 0.33 -> 0.50 s (+52%)
--   intsum    runtime 0.03 -> 0.12 s (+300%)
-- which reproduces (and understates) issue #133's relayed +20% binary / +8.4%
-- runtime claim.  The prelude object stays opt-in, for build-throughput-bound
-- CI gates that do not care about the binaries they produce.
--
-- ⚠️ CACHE KEY.  NOT the compiler-source fingerprint (`liveSourceFingerprint`,
-- medaka_cli.mdk) — that hashes `compiler/*.mdk` ONLY, and the object here does
-- not depend on a single one of those files while it DOES depend on things that
-- fingerprint cannot see: medaka_rt.c's own contents, the clang binary and its
-- version, MEDAKA_CLANG_OPT, and detectGC's discovered cflags.  Keying on the
-- compiler fingerprint would be silently wrong the moment medaka_rt.c changed
-- without a compiler-source edit alongside it.  What we hash, exactly and only:
-- the cc name, `cc --version`, the full compile flag list (opt level + -pthread
-- + gcSectionsCflags + detectGC's cflags), and the CONTENTS of medaka_rt.c.
--
-- ⚠️ KNOWN GAPS in that key — it is NOT a complete function of everything the
-- object depends on, and this comment used to read as though it were.  Inputs
-- that can change the emitted object WITHOUT changing the key:
--   * the include search path from the environment (CPATH, C_INCLUDE_PATH) — a
--     different gc.h found for the same cc/flags;
--   * an IN-PLACE upgrade of a system header or of libgc that leaves the cc
--     version string untouched (the .c source and flags are unchanged, so the
--     key is too — headers are not hashed, only medaka_rt.c itself);
--   * on macOS, SDKROOT / MACOSX_DEPLOYMENT_TARGET, which retarget the compile
--     without appearing in the flag list we hash.
-- Each is low-probability on a developer box and none is silent-wrongness in the
-- usual sense (a stale object still links and runs; it is stale, not wrong-for-
-- this-program).  Widening the key to cover them is real design work — hashing a
-- preprocessed translation unit, or the resolved header set — and is tracked as
-- a follow-up rather than bolted on here.  The escape hatch in the meantime is
-- MEDAKA_NO_OBJ_CACHE=1, or deleting the cache directory.
--
-- ⚠️ CONCURRENCY [G-BUILD-RACE].  The cache is written the same way the rest of
-- this driver writes shared paths: compile into an `mktemp`-allocated file
-- INSIDE the cache directory (so the rename is same-filesystem and therefore
-- atomic), then `mv` it into place.  A racing build either sees the old absence
-- and does the same work, or sees the finished object — never a partial one.
--
-- ⚠️ FAIL-OPEN, ALWAYS.  Every failure path here ends in either "" (the caller
-- compiles medaka_rt.c inline exactly as before) or a fresh compile over the bad
-- entry.  No cache problem — unset HOME, unwritable cache dir, missing
-- sha256sum, a failed mv, a truncated object (rtObjUsable) — may ever fail a
-- build that would otherwise succeed.
--
-- Escape hatches: MEDAKA_NO_OBJ_CACHE (any non-empty value) disables it;
-- MEDAKA_CACHE_DIR relocates it; an explicit MEDAKA_RT_OBJ still wins outright,
-- so every existing CI caller (test/build_oracles.sh, the engines gates) is
-- byte-for-byte unaffected.

-- Where the object cache lives.  "" = no cache (disabled, or no home to put it
-- in).  Per-USER and shared across projects on purpose: the object is a pure
-- function of medaka_rt.c and the clang flags, identical for every project on
-- the machine, so a per-project `.medaka/` would store N identical copies and
-- litter user repositories with build droppings for no benefit.
export
objCacheDir : Unit -> <IO> String
objCacheDir _ =
  if envOr "MEDAKA_NO_OBJ_CACHE" "" /= "" then ""
  else
    let explicit = envOr "MEDAKA_CACHE_DIR" ""
    if explicit /= "" then explicit
    else
      let xdg = envOr "XDG_CACHE_HOME" ""
      if xdg /= "" then joinPath xdg "medaka"
      else
        let home = envOr "HOME" ""
        if home == "" then "" else joinPath home ".cache/medaka"

-- The cache key: a hash over every input the object depends on.  Shelled out to
-- sha256sum/shasum/cksum through the same three-way fallback chain
-- `liveSourceFingerprint` uses, so a box with none of them degrades to cksum
-- rather than to a wrong answer.  The flag list is written to a file in the
-- build's OWN scratch dir and the cc/paths are passed as POSITIONAL ARGUMENTS
-- to `sh -c` (hence the "sh" argv[0] filler) rather than interpolated into the
-- script text — nothing here is exposed to shell word-splitting or quoting.
-- "" on any failure (caller then skips the cache entirely).
rtObjCacheKey : String -> String -> String -> List String -> String -> <IO> String
rtObjCacheKey cc rtC optFlag gcCflags tmpDir =
  let flagsPath = joinPath tmpDir "rtobj_flags"
  let flagsText = joinWith " " ([optFlag, "-pthread"] ++ gcSectionsCflags ++ gcCflags) ++ "\n"
  match writeFile flagsPath flagsText
    Err _ => ""
    Ok _ =>
      let script = stringConcat [
        "{ printf '%s\\n' \"$1\"; \"$1\" --version 2>/dev/null; cat \"$2\"; cat \"$3\"; } | ",
        "{ if command -v sha256sum >/dev/null 2>&1; then sha256sum; ",
        "elif command -v shasum >/dev/null 2>&1; then shasum -a 256; ",
        "else cksum; fi; } | cut -d' ' -f1",
      ]
      match runCommand "sh" ["-c", script, "sh", cc, flagsPath, rtC]
        Ok (0, out, _) => stringTrim out
        _ => ""

-- Resolve the cached runtime object, populating the cache on a miss.  Returns
-- the object path, or "" meaning "no cached object — compile the .c inline".
cachedRtObj : String -> String -> String -> List String -> String -> <IO> String
cachedRtObj cc rtC optFlag gcCflags tmpDir =
  let dir = objCacheDir ()
  if dir == "" then ""
  else
    let key = rtObjCacheKey cc rtC optFlag gcCflags tmpDir
    if key == "" then ""
    else
      let objPath = joinPath dir "rt-\{key}.o"
      let hit = if fileExists objPath then rtObjUsable objPath else False
      if hit then objPath else populateRtObj cc rtC optFlag gcCflags dir objPath

-- Sanity-check a cache HIT before trusting it (#2233 item 2).  The population
-- path is already write-then-rename, so a truncated object needs a crash or
-- power loss mid-writeback — but if that happens the object still EXISTS at the
-- expected path, and the next build fails with `undefined reference to 'main'`,
-- an error pointing nowhere near the cache and with no self-repair.
-- medaka_rt.c owns `int main` (see its bottom), so an object that does not
-- define it is not a usable runtime object whatever its size — which makes the
-- symbol a sharper check than a size floor a truncated object could still pass.
--
-- ⚠️ FAIL-OPEN IN BOTH DIRECTIONS, and the two directions differ deliberately:
--   * no `nm` on the box            -> ACCEPT.  Rejecting would silently disable
--     the cache everywhere nm is absent — a far bigger regression than the narrow
--     corruption case this guards.
--   * `nm` runs but cannot read the object, or reads it and finds no `main`
--                                   -> REJECT.  The caller then repopulates over
--     it (mktemp + `mv -f`), so a corrupted entry SELF-REPAIRS rather than
--     needing a manual clear.
-- Matches both `T main` (ELF) and `T _main` (Mach-O's leading underscore), per
-- [B-DUAL-PLATFORM].
rtObjUsable : String -> <IO> Bool
rtObjUsable objPath =
  let script = stringConcat [
    "command -v nm >/dev/null 2>&1 || exit 0\n",
    "syms=$(nm \"$1\" 2>/dev/null) || exit 1\n",
    "printf '%s\\n' \"$syms\" | grep -qE ' T _?main$'\n",
  ]
  match runCommand "sh" ["-c", script, "sh", objPath]
    Ok (0, _, _) => True
    _ => False

-- Cache MISS: compile medaka_rt.c with EXACTLY the flags clangLinkGo would have
-- applied to it inline (and exactly the flags emitRtObj uses — the same one
-- reader for the opt level and the same detectGC cflags, so the three can never
-- drift), into an mktemp file inside the cache dir, then atomically rename.
populateRtObj : String -> String -> String -> List String -> String -> String -> <IO> String
populateRtObj cc rtC optFlag gcCflags dir objPath = match runCommand "mkdir" ["-p", dir]
  Ok (0, _, _) => match runCommand "mktemp" [joinPath dir "rtobj_XXXXXX"]
    Ok (0, tOut, _) =>
      let tmpObj = stringTrim tOut
      if tmpObj == "" then ""
      else
        let ccArgs = [optFlag, "-pthread"] ++ gcSectionsCflags ++ gcCflags ++ ["-c", rtC, "-o", tmpObj]
        match runCommand cc ccArgs
          Ok (0, _, _) => match runCommand "mv" ["-f", tmpObj, objPath]
            Ok (0, _, _) => objPath
            _ =>
              let _ = removeFile tmpObj
              ""
          _ =>
            let _ = removeFile tmpObj
            ""
    _ => ""
  _ => ""

-- The `[perf] rt-obj` row's ops field: which of the three runtime-object paths
-- this build actually took, so the row is self-explaining in a log.
rtObjNote : String -> String -> String
rtObjNote rtObjEnv rtCached =
  if rtObjEnv /= "" && rtCached == rtObjEnv then
    "MEDAKA_RT_OBJ (explicit)"
  else if rtCached == "" then
    "inline (no cache)"
  else
    "cache \{rtCached}"

-- Timing wrapper: opens the clang-half stopwatch (and reads MEDAKA_PERF once)
-- before `detectGC` runs, so the gc probe is inside the measured window rather
-- than falling into an unattributed gap between the CLI's rows.  Split out only
-- so the body below keeps its `= match detectGC …` head shape.
clangLinkGo : String -> String -> String -> String -> String -> String -> List String -> <IO> BuildResult
clangLinkGo cc rtC llPath outPath inputAbs tmpDir libFlags =
  clangLinkTimed
    cc
    rtC
    llPath
    outPath
    inputAbs
    tmpDir
    libFlags
    (perfEnabled ())
    (now ())

clangLinkTimed : String -> String -> String -> String -> String -> String -> List String -> Bool -> Float -> <IO> BuildResult
clangLinkTimed cc rtC llPath outPath inputAbs tmpDir libFlags perfOn tLink0 = match detectGC cc tmpDir
  None => BuildErr "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config"
  Some (gcCflags, gcLibs) =>
    -- `[perf] gc-probe` gets its OWN row rather than being folded into `rt-obj`:
    -- detectGC shells out (pkg-config, then possibly brew, then a real clang
    -- compile of a probe .c), so on a box where pkg-config misses it is not a
    -- rounding error, and charging that to the object cache would misattribute
    -- it to exactly the thing this slice is trying to measure.
    let tGcProbe = now ()
    let _ = emitPhase perfOn "gc-probe" (tGcProbe - tLink0) cc
    let optFlag = clangOptFlag
    -- CI FAST PATH (MEDAKA_RT_OBJ).  Every `medaka build` otherwise recompiles the
    -- identical runtime/medaka_rt.c from scratch (~0.6s of clang each).  A gate
    -- that does hundreds of builds can precompile the runtime ONCE (via
    -- `medaka build --emit-rt-obj <path>`, which compiles medaka_rt.c with EXACTLY
    -- these same flags — see emitRtObj) and point MEDAKA_RT_OBJ at the object; we
    -- then link that object instead of recompiling the .c.  The precompile path
    -- reuses clangOptFlag + detectGC, so the object's flags can't drift from the
    -- link's.  Purely additive: unset (or a missing file) → the exact original
    -- behavior, byte-for-byte, so an ordinary user build is unaffected.  The
    -- inline-vs-prebuilt binaries are proven byte-identical by
    -- test/diff_compiler_rt_obj.sh.
    --
    -- SINCE #133/G1 this is no longer the only way to get the prebuilt object:
    -- an explicit MEDAKA_RT_OBJ still WINS outright (so every existing CI caller
    -- keeps its exact behavior), but when it is unset we now consult the
    -- automatic, self-managed, fingerprint-keyed object cache above — which is
    -- what makes the ~0.76 s saving the DEFAULT for ordinary users instead of a
    -- CI-only trick.  `cachedRtObj` fails open to "" (⇒ rtC, the inline compile).
    let rtObjEnv = envOr "MEDAKA_RT_OBJ" ""
    let rtCached = if rtObjEnv /= "" && fileExists rtObjEnv then
      rtObjEnv
    else
      cachedRtObj cc rtC optFlag gcCflags tmpDir
    let rtInput = if rtCached == "" then rtC else rtCached
    let tRtObj = now ()
    let _ = emitPhase perfOn "rt-obj" (tRtObj - tGcProbe) (rtObjNote rtObjEnv rtCached)
    -- CI FAST PATH (MEDAKA_PRELUDE_OBJ, issue #118) — the LINK half.  Exactly the
    -- MEDAKA_RT_OBJ trick one level up: the prelude is 88% of a small program's IR,
    -- and clang -O2 re-optimises all of it on every build.  Precompile it ONCE
    -- (`medaka build --emit-prelude-obj <path>`, emitPreludeObj — same clangOptFlag,
    -- same detectGC cflags, so the object's flags cannot drift from the link's) and
    -- link the object instead.  The emitter was told to emit the PROGRAM half above,
    -- so the two are complementary halves of one module: prelude.o defines
    -- `@mdk_core__*`/`@mdk_impl_*`, the program half defines its own code, the
    -- per-program `@mdk_disp_*` dispatchers, and `@mdk_program_main`.
    --
    -- Purely additive: unset (or a missing file) → the exact original behavior,
    -- byte-for-byte, so an ordinary user build is unaffected.  It is opt-in on
    -- purpose and NOT the default for `--release`: separate objects cannot inline
    -- prelude functions into user code without LTO.  Proven output-identical
    -- inline-vs-prebuilt by test/diff_compiler_prelude_obj.sh.
    let preludeObj = preludeObjOf ()
    let objInputs = if preludeObj == "" then [llPath, rtInput] else [llPath, preludeObj, rtInput]
    -- The runtime (runtime/medaka_rt.c) runs the compiled program on a 256 MB
    -- worker thread via GC_pthread_create, so it self-provisions its stack: no
    -- Mach-O-only `-Wl,-stack_size` link flag is needed on either platform.
    -- `-pthread` (thread runtime) and `-lm` (math externs) go on every link.
    let sectionsLink = gcSectionsLinkFlag ()
    let clangArgs = [optFlag, "-pthread"] ++ gcSectionsCflags ++ gcCflags ++ objInputs ++ libFlags ++ gcLibs ++ [sectionsLink, "-lm", "-o", outPath]
    -- Bound to a `let` (not matched directly) purely so the stopwatch can be read
    -- ONCE, after the clang child exits, without duplicating the row across three
    -- result arms.  Medaka is strict, so this runs clang exactly where the
    -- `match` used to.
    let ccRes = runCommand cc clangArgs
    let tClang = now ()
    let _ = emitPhase perfOn "clang" (tClang - tRtObj) inputAbs
    match ccRes
      Err e => BuildErr "error: could not run clang (\{cc}): \{e}"
      Ok (0, _, _) => BuildOk "built \{inputAbs} -> \{outPath}"
      Ok (_, _, ccErr) =>
        BuildErr "error: clang failed linking \{inputAbs}\n\{ccErr}"

-- ---- the prelude object (issue #118) ---------------------------------------
-- MEDAKA_PRELUDE_OBJ, honoured only when it names a file that exists (same
-- discipline as MEDAKA_RT_OBJ: a stale/deleted path degrades to the ordinary
-- build, it does not fail it).  ONE reader, consulted by both the emit step (which
-- must then emit the program half) and the link step (which must then link the
-- object) — so the two can never disagree about whether the fast path is on, which
-- would be a half-linked binary.
preludeObjOf : Unit -> <IO> String
preludeObjOf _ =
  let p = envOr "MEDAKA_PRELUDE_OBJ" ""
  if p /= "" && fileExists p then p else ""

-- Run a command with MEDAKA_EMIT_HALF set, via `env` — Medaka has no setEnv extern
-- and runCommand takes no environment, and `env` is POSIX on both platforms.  argv[0]
-- stays the emitter's own absolute path, so its argv[0]-relative asset lookup is
-- unaffected.
withEmitHalf : String -> String -> List String -> (String, List String)
withEmitHalf half prog args =
  ("env", ["MEDAKA_EMIT_HALF=\{half}", prog] ++ args)

-- `medaka build --emit-prelude-obj <path>`: emit stdlib/core.mdk ALONE as a
-- library (MEDAKA_EMIT_HALF=prelude) and compile it to a reusable object with
-- EXACTLY the flags clangLink would apply to the program half — the same
-- clangOptFlag opt level, the same `-pthread`, the same gcSectionsCflags, the same
-- detectGC cflags.  Having the COMPILER decide those (rather than a gate
-- hand-rolling a clang line with guessed flags) is the whole point: it removes the
-- drift surface, exactly as emitRtObj does for the C runtime.
--
-- The emitter needs an ENTRY, so we hand it a `main = ()` stub in the scratch dir.
-- The stub contributes nothing (mode 1 emits no `@mdk_program_main`, and a nullary
-- `main` is neither a fn bind nor a value bind) — it exists only to give the loader
-- a graph to walk.  DCE is off in this mode, so what lands in the object is the
-- WHOLE prelude, not what the stub happened to reach.
export
emitPreludeObj : String -> String -> String -> String -> <IO> BuildResult
emitPreludeObj cc root medaka outObjPath = match makeTempDir ()
  Err e => BuildErr "error: could not create a scratch directory for the prelude compile: \{e}"
  Ok tmpDir =>
    let res = emitPreludeObjIn cc root medaka outObjPath tmpDir
    let _ = cleanupTempDir tmpDir
    res

emitPreludeObjIn : String -> String -> String -> String -> String -> <IO> BuildResult
emitPreludeObjIn cc root medaka outObjPath tmpDir = match detectGC cc tmpDir
  None => BuildErr "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config"
  Some (gcCflags, _gcLibs) =>
    let stubPath = joinPath tmpDir "prelude_entry.mdk"
    let llPath = joinPath tmpDir "prelude.ll"
    match writeFile stubPath "main = ()\n"
      Err e =>
        BuildErr "error: could not write the prelude-object entry stub: \{e}"
      Ok _ =>
        let emitter = joinPath root "compiler/entries/llvm_emit_modules_main.mdk"
        let emitArgsBase = [
          joinPath root "stdlib/runtime.mdk",
          joinPath root "stdlib/core.mdk",
          stubPath,
          tmpDir,
          joinPath root "compiler",
          joinPath root "stdlib",
        ]
        let emitter2 = envOr "MEDAKA_EMITTER" defaultMedakaEmitter
        let useNative = emitter2 /= ""
        let emitProg0 = if useNative then emitter2 else medaka
        let emitArgs0 = if useNative then
          emitArgsBase
        else
          "run" :: emitter::emitArgsBase
        let (emitProg, emitArgs) = withEmitHalf "prelude" emitProg0 emitArgs0
        match runCommand emitProg emitArgs
          Err e => BuildErr "error: could not run emitter (\{emitProg}): \{e}"
          Ok (code, irRaw, emitErr) => if code /= 0 then BuildErr "error: emitter failed emitting the prelude object\n\{emitErr}"
          else
            let ir = stripTrailingUnit irRaw
            if stringLength ir == 0 then BuildErr "error: emitter produced empty IR for the prelude object\n\{emitErr}"
            else match writeFile llPath ir
              Err e => BuildErr ("error: could not write prelude IR: " ++ e)
              Ok _ =>
                let optFlag = clangOptFlag
                let ccArgs = [optFlag, "-pthread"] ++ gcSectionsCflags ++ gcCflags ++ ["-c", llPath, "-o", outObjPath]
                match runCommand cc ccArgs
                  Err e => BuildErr "error: could not run clang (\{cc}): \{e}"
                  Ok (0, _, _) => BuildOk ("compiled prelude object -> \{outObjPath}" ++ emitStderrNote emitErr)
                  Ok (_, _, ccErr) => BuildErr "error: clang failed compiling the prelude object\n\{ccErr}"

-- ---- precompile the C runtime object (`medaka build --emit-rt-obj <path>`) ----
-- Compile runtime/medaka_rt.c to a standalone object with EXACTLY the flags
-- clangLink would apply to it inline — the same clangOptFlag opt level, the same
-- `-pthread`, and the same detectGC-derived gcCflags — so linking the resulting
-- object is indistinguishable from compiling the .c inline (proven byte-identical
-- by test/diff_compiler_rt_obj.sh).  gcLibs / -lm are link-only and correctly
-- omitted from a `-c` compile.  Having the COMPILER decide the flags (rather than
-- a gate hand-rolling `clang -c medaka_rt.c` with guessed flags) is the whole
-- point: it removes the drift surface that this optimization keeps rediscovering.
export
emitRtObj : String -> String -> String -> <IO> BuildResult
emitRtObj cc root outObjPath = match makeTempDir ()
  Err e => BuildErr "error: could not create a scratch directory for the runtime compile: \{e}"
  Ok tmpDir =>
    let res = match detectGC cc tmpDir
      None => BuildErr "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config"
      Some (gcCflags, _gcLibs) =>
        let optFlag = clangOptFlag
        let rtC = joinPath root "runtime/medaka_rt.c"
        -- -c (compile-only): the section-GC LINK flag has no meaning here — only
        -- the compile flags (gcSectionsCflags) apply, and they must match
        -- clangLink's exactly so the prebuilt object is indistinguishable from
        -- an inline compile (test/diff_compiler_rt_obj.sh).
        let ccArgs = [optFlag, "-pthread"] ++ gcSectionsCflags ++ gcCflags ++ ["-c", rtC, "-o", outObjPath]
        match runCommand cc ccArgs
          Err e => BuildErr "error: could not run clang (\{cc}): \{e}"
          Ok (0, _, _) => BuildOk "compiled runtime object -> \{outObjPath}"
          Ok (_, _, ccErr) =>
            BuildErr "error: clang failed compiling runtime object\n\{ccErr}"
    let _ = cleanupTempDir tmpDir
    res
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "stringTrim" false) (mem "joinWith" false))))
(DUse false (UseGroup ("string") ((mem "words" false))))
(DUse false (UseGroup ("support" "timer") ((mem "perfEnabled" false) (mem "now" false) (mem "emitPhase" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false) (mem "findProjectRootOrSelf" false) (mem "readForeignLibs" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "chopExt" false) (mem "joinPath" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false))))
(DUse false (UseGroup ("frontend" "parse_cache") ((mem "notePreludeParse" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "parseErrDiag" false) (mem "ppDiagCliSrc" false))))
(DData Public "BuildResult" () ((variant "BuildOk" (ConPos (TyCon "String"))) (variant "BuildErr" (ConPos (TyCon "String")))) ())
(DData Public "BuildTarget" () ((variant "TNative" (ConPos)) (variant "TWasm" (ConPos))) ())
(DTypeSig false "appendNote" (TyFun (TyCon "String") (TyFun (TyCon "BuildResult") (TyCon "BuildResult"))))
(DFunDef false "appendNote" ((PVar "note") (PCon "BuildOk" (PVar "m"))) (EApp (EVar "BuildOk") (EBinOp "++" (EVar "m") (EVar "note"))))
(DFunDef false "appendNote" ((PVar "note") (PCon "BuildErr" (PVar "m"))) (EApp (EVar "BuildErr") (EBinOp "++" (EVar "m") (EVar "note"))))
(DTypeSig true "envOr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "envOr" ((PVar "name") (PVar "dflt")) (EMatch (EApp (EVar "getEnv") (EVar "name")) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EVar "dflt") (EVar "v"))) (arm (PCon "None") () (EVar "dflt"))))
(DTypeSig true "exeDir" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "exeDir" () (EApp (EVar "dirOf") (EApp (EVar "executablePath") (ELit LUnit))))
(DTypeSig true "defaultMedakaRoot" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "defaultMedakaRoot" () (EVar "exeDir"))
(DTypeSig true "defaultMedakaEmitter" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "defaultMedakaEmitter" () (EApp (EApp (EVar "joinPath") (EVar "exeDir")) (ELit (LString "medaka_emitter"))))
(DTypeSig true "readPreludeFile" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "readPreludeFile" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: cannot read the stdlib prelude at \"")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "\" ("))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ")\n  set MEDAKA_ROOT to your medaka repo/install root, run from the project root, or place stdlib/ next to the medaka binary"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "pe")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path")) (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "pe"))))) (ELit (LString "\n  (while loading the implicit prelude)"))))) (arm (PCon "Ok" (PVar "decls")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "notePreludeParse") (EVar "src")) (EVar "decls"))) (DoExpr (EApp (EVar "Ok") (EVar "src")))))))))
(DTypeSig false "stripTrailingUnit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripTrailingUnit" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 3)))) (EVar "n")) (EVar "s")) (ELit (LString "()\n")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 3)))) (EVar "s")) (EVar "s")))))
(DTypeSig true "makeTempDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "makeTempDir" (PWild) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (ELit (LString "/tmp/medaka_build_XXXXXX")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "dir") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "mktemp -d printed no path"))) (EApp (EVar "Ok") (EVar "dir")))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "mtErr"))) () (EBlock (DoLet false false (PVar "msg") (EApp (EVar "stringTrim") (EVar "mtErr"))) (DoExpr (EApp (EVar "Err") (EIf (EBinOp "==" (EVar "msg") (ELit (LString ""))) (ELit (LString "mktemp -d failed")) (EVar "msg"))))))))
(DTypeSig false "removeEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "removeEntries" (PWild (PList)) (ELit LUnit))
(DFunDef false "removeEntries" ((PVar "dir") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "n")))) (DoExpr (EApp (EApp (EVar "removeEntries") (EVar "dir")) (EVar "rest")))))
(DTypeSig true "cleanupTempDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "cleanupTempDir" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "entries")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "removeEntries") (EVar "dir")) (EVar "entries"))) (DoLet false false PWild (EApp (EVar "removeDir") (EVar "dir"))) (DoExpr (ELit LUnit))))))
(DTypeSig false "sweepStaleTempDirs" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "sweepStaleTempDirs" (PWild) (EBlock (DoLet false false (PVar "findArgs") (EListLit (ELit (LString "/tmp")) (ELit (LString "-maxdepth")) (ELit (LString "1")) (ELit (LString "-type")) (ELit (LString "d")) (ELit (LString "-name")) (ELit (LString "medaka_build_*")) (ELit (LString "-mmin")) (ELit (LString "+360")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "find"))) (EVar "findArgs")) (arm (PCon "Ok" (PTuple PWild (PVar "out") PWild)) () (EApp (EVar "sweepEachStale") (EApp (EVar "words") (EVar "out")))) (arm (PCon "Err" PWild) () (ELit LUnit))))))
(DTypeSig false "sweepEachStale" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "sweepEachStale" ((PList)) (ELit LUnit))
(DFunDef false "sweepEachStale" ((PCons (PVar "d") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "d"))) (DoExpr (EApp (EVar "sweepEachStale") (EVar "rest")))))
(DTypeSig false "detectGC" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGC" ((PVar "cc") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--exists")) (ELit (LString "bdw-gc")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EBlock (DoLet false false (PVar "cflags") (EApp (EApp (EVar "gcQuery") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--cflags")) (ELit (LString "bdw-gc"))))) (DoLet false false (PVar "libs") (EApp (EApp (EVar "gcQuery") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--libs")) (ELit (LString "bdw-gc"))))) (DoExpr (EApp (EVar "Some") (ETuple (EApp (EVar "words") (EVar "cflags")) (EApp (EVar "words") (EVar "libs"))))))) (arm PWild () (EApp (EApp (EVar "detectGCBrew") (EVar "cc")) (EVar "tmpDir")))))
(DTypeSig false "gcQuery" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "gcQuery" ((PVar "prog") (PVar "args")) (EMatch (EApp (EApp (EVar "runCommand") (EVar "prog")) (EVar "args")) (arm (PCon "Ok" (PTuple PWild (PVar "out") PWild)) () (EApp (EVar "stringTrim") (EVar "out"))) (arm (PCon "Err" PWild) () (ELit (LString "")))))
(DTypeSig false "detectGCBrew" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGCBrew" ((PVar "cc") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "brew"))) (EListLit (ELit (LString "--prefix")) (ELit (LString "bdw-gc")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "prefix") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "prefix") (ELit (LString ""))) (EApp (EVar "fileExists") (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "include/gc.h"))))) (EApp (EVar "Some") (ETuple (EListLit (EBinOp "++" (ELit (LString "-I")) (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "include"))))) (EListLit (EBinOp "++" (ELit (LString "-L")) (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "lib")))) (ELit (LString "-lgc"))))) (EApp (EApp (EVar "detectGCBare") (EVar "cc")) (EVar "tmpDir")))))) (arm PWild () (EApp (EApp (EVar "detectGCBare") (EVar "cc")) (EVar "tmpDir")))))
(DTypeSig false "detectGCBare" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGCBare" ((PVar "cc") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "probe") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "gcprobe.c")))) (DoLet false false (PVar "probeOut") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "gcprobe.out")))) (DoLet false false PWild (EApp (EApp (EVar "writeFile") (EVar "probe")) (ELit (LString "#include <gc.h>\nint main(void){return 0;}\n")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EListLit (EVar "probe") (ELit (LString "-lgc")) (ELit (LString "-o")) (EVar "probeOut"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "Some") (ETuple (EListLit) (EListLit (ELit (LString "-lgc")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "gcSectionsCflags" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "gcSectionsCflags" () (EListLit (ELit (LString "-ffunction-sections")) (ELit (LString "-fdata-sections"))))
(DTypeSig false "gcSectionsLinkFlag" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "gcSectionsLinkFlag" (PWild) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "uname"))) (EListLit (ELit (LString "-s")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EVar "out")) (ELit (LString "Darwin"))) (ELit (LString "-Wl,-dead_strip")) (ELit (LString "-Wl,--gc-sections")))) (arm PWild () (ELit (LString "-Wl,--gc-sections")))))
(DTypeSig false "effectiveKeepIr" (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "effectiveKeepIr" ((PVar "cliFlag")) (EBinOp "||" (EVar "cliFlag") (EBinOp "/=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_KEEP_IR"))) (ELit (LString ""))) (ELit (LString "")))))
(DTypeSig false "keepIrNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "keepIrNote" ((PVar "path") (PVar "contents")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "contents")) (arm (PCon "Ok" PWild) () (EBinOp "++" (ELit (LString "\nkept IR: ")) (EVar "path"))) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\nwarning: could not keep IR at ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": "))) (EVar "e")))))
(DTypeSig false "emitStderrNote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "emitStderrNote" ((PVar "emitErr")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "emitErr")) (ELit (LInt 0))) (ELit (LString "")) (EBinOp "++" (ELit (LString "\n")) (EVar "emitErr"))))
(DTypeSig true "runBuild" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))))
(DFunDef false "runBuild" ((PVar "root") (PVar "medaka") (PVar "cc") (PCon "TNative") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EBlock (DoLet false false PWild (EApp (EVar "sweepStaleTempDirs") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNative") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")))))
(DFunDef false "runBuild" ((PVar "root") (PVar "medaka") (PVar "cc") (PCon "TWasm") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EBlock (DoLet false false PWild (EApp (EVar "sweepStaleTempDirs") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runBuildWasm") (EVar "root")) (EVar "medaka")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")))))
(DTypeSig false "runBuildNative" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult")))))))))
(DFunDef false "runBuildNative" ((PVar "root") (PVar "medaka") (PVar "cc") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the build: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeIn") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "inputAbs")) (EVar "outPath")) (EVar "tmpDir")) (EVar "keepIrCli"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
(DTypeSig false "runBuildNativeIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))))
(DFunDef false "runBuildNativeIn" ((PVar "root") (PVar "medaka") (PVar "cc") (PVar "inputAbs") (PVar "outPath") (PVar "tmpDir") (PVar "keepIrCli")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeRoots") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "inputAbs")) (EVar "outPath")) (EVar "tmpDir")) (EVar "keepIrCli")) (EListLit)))
(DTypeSig true "runBuildNativeRoots" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "BuildResult")))))))))))
(DFunDef false "runBuildNativeRoots" ((PVar "root") (PVar "medaka") (PVar "cc") (PVar "inputAbs") (PVar "outPath") (PVar "tmpDir") (PVar "keepIrCli") (PVar "extraRoots")) (EBlock (DoLet false false (PVar "emitter") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler/entries/llvm_emit_modules_main.mdk")))) (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk")))) (DoLet false false (PVar "preludeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk")))) (DoLet false false (PVar "rtC") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "runtime/medaka_rt.c")))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoLet false false (PVar "stdlibDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib")))) (DoLet false false (PVar "inputRoots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "inputAbs"))) (EVar "extraRoots"))) (DoLet false false (PVar "llPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "program.ll")))) (DoLet false false (PVar "emitArgsBase") (EBinOp "++" (EBinOp "++" (EListLit (EVar "runtimeP") (EVar "preludeP") (EVar "inputAbs")) (EVar "inputRoots")) (EListLit (EVar "compilerDir") (EVar "stdlibDir")))) (DoLet false false (PVar "emitter2") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EVar "defaultMedakaEmitter"))) (DoLet false false (PVar "useNative") (EBinOp "/=" (EVar "emitter2") (ELit (LString "")))) (DoLet false false (PVar "emitProg0") (EIf (EVar "useNative") (EVar "emitter2") (EVar "medaka"))) (DoLet false false (PVar "emitArgs0") (EIf (EVar "useNative") (EVar "emitArgsBase") (EBinOp "::" (ELit (LString "run")) (EBinOp "::" (EVar "emitter") (EVar "emitArgsBase"))))) (DoLet false false (PTuple (PVar "emitProg") (PVar "emitArgs")) (EIf (EBinOp "==" (EApp (EVar "preludeObjOf") (ELit LUnit)) (ELit (LString ""))) (ETuple (EVar "emitProg0") (EVar "emitArgs0")) (EApp (EApp (EApp (EVar "withEmitHalf") (ELit (LString "program"))) (EVar "emitProg0")) (EVar "emitArgs0")))) (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "tEmit0") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "emitRes") (EApp (EApp (EVar "runCommand") (EVar "emitProg")) (EVar "emitArgs"))) (DoLet false false (PVar "tEmit1") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "emit-ir"))) (EBinOp "-" (EVar "tEmit1") (EVar "tEmit0"))) (EVar "inputAbs"))) (DoExpr (EMatch (EVar "emitRes") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run emitter (")) (EApp (EVar "display") (EVar "emitProg"))) (ELit (LString "): "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "irRaw") (PVar "emitErr"))) () (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter failed compiling ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "emitErr"))) (ELit (LString "")))) (EBlock (DoLet false false (PVar "ir") (EApp (EVar "stripTrailingUnit") (EVar "irRaw"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "ir")) (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter produced empty IR for ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "emitErr"))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "llPath")) (EVar "ir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not write IR: ")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "ffiRoot") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "inputAbs")))) (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clangLink") (EVar "cc")) (EVar "rtC")) (EVar "llPath")) (EVar "outPath")) (EVar "inputAbs")) (EVar "tmpDir")) (EVar "ffiRoot")) (EApp (EVar "readForeignLibs") (EVar "ffiRoot")))) (DoLet false false (PVar "note") (EBinOp "++" (EIf (EApp (EVar "effectiveKeepIr") (EVar "keepIrCli")) (EApp (EApp (EVar "keepIrNote") (EBinOp "++" (EVar "outPath") (ELit (LString ".ll")))) (EVar "ir")) (ELit (LString ""))) (EApp (EVar "emitStderrNote") (EVar "emitErr")))) (DoExpr (EApp (EApp (EVar "appendNote") (EVar "note")) (EVar "res")))))))))))))))
(DTypeSig false "runBuildWasm" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))
(DFunDef false "runBuildWasm" ((PVar "root") (PVar "medaka") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the build: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildWasmIn") (EVar "root")) (EVar "medaka")) (EVar "inputAbs")) (EVar "outPath")) (EVar "tmpDir")) (EVar "keepIrCli"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
(DTypeSig false "runBuildWasmIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult")))))))))
(DFunDef false "runBuildWasmIn" ((PVar "root") (PVar "medaka") (PVar "inputAbs") (PVar "outPath") (PVar "tmpDir") (PVar "keepIrCli")) (EBlock (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk")))) (DoLet false false (PVar "preludeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk")))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoLet false false (PVar "stdlibDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib")))) (DoLet false false (PVar "inputRoots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "inputAbs")))) (DoLet false false (PVar "watPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "program.wat")))) (DoLet false false (PVar "emitArgsBase") (EBinOp "++" (EBinOp "++" (EListLit (EVar "runtimeP") (EVar "preludeP") (EVar "inputAbs")) (EVar "inputRoots")) (EListLit (EVar "compilerDir") (EVar "stdlibDir")))) (DoLet false false (PVar "wasmEmitter") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_WASM_EMITTER"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "wasmEmitter") (ELit (LString ""))) (EApp (EVar "BuildErr") (ELit (LString "error: --target wasm needs a compiled wasm emitter — set MEDAKA_WASM_EMITTER to its path\n  build one with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)"))) (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "wasmEmitter"))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: MEDAKA_WASM_EMITTER points to a missing binary: ")) (EApp (EVar "display") (EVar "wasmEmitter"))) (ELit (LString "\n  build it with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)")))) (EMatch (EApp (EVar "probeWasmTools") (ELit LUnit)) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: wasm-tools not found on PATH — install wasm-tools (cargo install wasm-tools or brew install wasm-tools) for --target wasm")))) (arm (PCon "Some" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (EVar "wasmEmitter")) (EVar "emitArgsBase")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run wasm emitter (")) (EApp (EVar "display") (EVar "wasmEmitter"))) (ELit (LString "): "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "watRaw") (PVar "emitErr"))) () (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm emitter failed compiling ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "emitErr"))) (ELit (LString "")))) (EBlock (DoLet false false (PVar "wat") (EApp (EVar "stripTrailingUnit") (EVar "watRaw"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "wat")) (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm emitter produced empty WAT for ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "emitErr"))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "watPath")) (EVar "wat")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not write WAT: ")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EVar "wasmAssemble") (EVar "watPath")) (EVar "outPath")) (EVar "inputAbs"))) (DoLet false false (PVar "note") (EBinOp "++" (EIf (EApp (EVar "effectiveKeepIr") (EVar "keepIrCli")) (EApp (EApp (EVar "keepIrNote") (EBinOp "++" (EVar "outPath") (ELit (LString ".wat")))) (EVar "wat")) (ELit (LString ""))) (EApp (EVar "emitStderrNote") (EVar "emitErr")))) (DoExpr (EApp (EApp (EVar "appendNote") (EVar "note")) (EVar "res")))))))))))))))))))
(DTypeSig false "probeWasmTools" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Unit")))))
(DFunDef false "probeWasmTools" (PWild) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "--version")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "Some") (ELit LUnit))) (arm PWild () (EVar "None"))))
(DTypeSig false "wasmAssemble" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult"))))))
(DFunDef false "wasmAssemble" ((PVar "watPath") (PVar "outPath") (PVar "inputAbs")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "parse")) (EVar "watPath") (ELit (LString "-o")) (EVar "outPath"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not run wasm-tools parse: ")) (EVar "e")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "validate")) (ELit (LString "--features=all")) (EVar "outPath"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not run wasm-tools validate: ")) (EVar "e")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "strip")) (ELit (LString "--all")) (EVar "outPath") (ELit (LString "-o")) (EVar "outPath"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not run wasm-tools strip: ")) (EVar "e")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "built ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString " -> "))) (EApp (EVar "display") (EVar "outPath"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "stripErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm-tools strip failed on ")) (EApp (EVar "display") (EVar "outPath"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "stripErr"))) (ELit (LString ""))))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "valErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm-tools validate rejected ")) (EApp (EVar "display") (EVar "outPath"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "valErr"))) (ELit (LString ""))))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "parseErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm-tools parse failed assembling ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "parseErr"))) (ELit (LString "")))))))
(DTypeSig false "clangOptFlag" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "clangOptFlag" () (EBlock (DoLet false false (PVar "optFlagRaw") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_CLANG_OPT"))) (ELit (LString "-O2")))) (DoExpr (EIf (EBinOp "==" (EVar "optFlagRaw") (ELit (LString ""))) (ELit (LString "-O2")) (EVar "optFlagRaw")))))
(DTypeSig false "clangLink" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyEffect ("IO") None (TyCon "BuildResult")))))))))))
(DFunDef false "clangLink" ((PVar "cc") (PVar "rtC") (PVar "llPath") (PVar "outPath") (PVar "inputAbs") (PVar "tmpDir") (PVar "projRoot") (PVar "libs")) (EBlock (DoLet false false (PVar "libErr") (EApp (EApp (EApp (EApp (EVar "foreignLibErr") (EVar "cc")) (EVar "tmpDir")) (EVar "projRoot")) (EVar "libs"))) (DoExpr (EIf (EBinOp "/=" (EVar "libErr") (ELit (LString ""))) (EApp (EVar "BuildErr") (EVar "libErr")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clangLinkGo") (EVar "cc")) (EVar "rtC")) (EVar "llPath")) (EVar "outPath")) (EVar "inputAbs")) (EVar "tmpDir")) (EApp (EVar "libLinkFlags") (EVar "libs")))))))
(DTypeSig false "libLinkFlags" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "libLinkFlags" ((PList)) (EListLit))
(DFunDef false "libLinkFlags" ((PCons (PTuple (PVar "name") (PVar "dir")) (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "-l")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "-L")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "-l")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EVar "libLinkFlags") (EVar "rest"))))))
(DTypeSig false "foreignLibErr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "foreignLibErr" (PWild PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "foreignLibErr" ((PVar "cc") (PVar "tmpDir") (PVar "projRoot") (PVar "libs")) (EBlock (DoLet false false (PVar "probeC") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "ffi_lib_probe.c")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "probeC")) (ELit (LString "int main(void) { return 0; }\n"))) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not write the foreign-library probe source: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "foreignLibErrGo") (EVar "cc")) (EVar "tmpDir")) (EVar "projRoot")) (EVar "probeC")) (EVar "libs")))))))
(DTypeSig false "foreignLibErrGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "foreignLibErrGo" (PWild PWild PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "foreignLibErrGo" ((PVar "cc") (PVar "tmpDir") (PVar "projRoot") (PVar "probeC") (PCons (PTuple (PVar "name") (PVar "dir")) (PVar "rest"))) (EBlock (DoLet false false (PVar "probeOut") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "ffi_lib_probe.out")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EBinOp "++" (EListLit (EVar "probeC") (ELit (LString "-o")) (EVar "probeOut")) (EApp (EVar "libLinkFlags") (EListLit (ETuple (EVar "name") (EVar "dir")))))) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run clang (")) (EApp (EVar "display") (EVar "cc"))) (ELit (LString ") to check foreign library '"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "': "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EApp (EApp (EApp (EApp (EVar "foreignLibErrGo") (EVar "cc")) (EVar "tmpDir")) (EVar "projRoot")) (EVar "probeC")) (EVar "rest"))) (arm (PCon "Ok" (PTuple PWild PWild PWild)) () (EApp (EApp (EApp (EVar "missingLibMsg") (EVar "projRoot")) (EVar "name")) (EVar "dir")))))))
(DTypeSig false "missingLibMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "missingLibMsg" ((PVar "projRoot") (PVar "name") (PVar "dir")) (EBlock (DoLet false false (PVar "searched") (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (ELit (LString "the linker's default search path")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString ", nor on the linker's default search path"))))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "error [B-FFI-LIB-NOT-FOUND]: foreign library '")) (EVar "name") (ELit (LString "' was not found in ")) (EVar "searched") (ELit (LString "\n")) (ELit (LString "  declared by the key '")) (EVar "name") (ELit (LString "' under [foreign-libraries] in ")) (EVar "projRoot") (ELit (LString "/medaka.toml\n")) (ELit (LString "  install the library, or point that key at the directory holding it: ")) (EVar "name") (ELit (LString " = \"vendor/lib\"")))))))
(DTypeSig true "objCacheDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "objCacheDir" (PWild) (EIf (EBinOp "/=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_NO_OBJ_CACHE"))) (ELit (LString ""))) (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "explicit") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_CACHE_DIR"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "/=" (EVar "explicit") (ELit (LString ""))) (EVar "explicit") (EBlock (DoLet false false (PVar "xdg") (EApp (EApp (EVar "envOr") (ELit (LString "XDG_CACHE_HOME"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "/=" (EVar "xdg") (ELit (LString ""))) (EApp (EApp (EVar "joinPath") (EVar "xdg")) (ELit (LString "medaka"))) (EBlock (DoLet false false (PVar "home") (EApp (EApp (EVar "envOr") (ELit (LString "HOME"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "home") (ELit (LString ""))) (ELit (LString "")) (EApp (EApp (EVar "joinPath") (EVar "home")) (ELit (LString ".cache/medaka"))))))))))))))
(DTypeSig false "rtObjCacheKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "rtObjCacheKey" ((PVar "cc") (PVar "rtC") (PVar "optFlag") (PVar "gcCflags") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "flagsPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "rtobj_flags")))) (DoLet false false (PVar "flagsText") (EBinOp "++" (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcSectionsCflags")) (EVar "gcCflags"))) (ELit (LString "\n")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "flagsPath")) (EVar "flagsText")) (arm (PCon "Err" PWild) () (ELit (LString ""))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "script") (EApp (EVar "stringConcat") (EListLit (ELit (LString "{ printf '%s\\n' \"$1\"; \"$1\" --version 2>/dev/null; cat \"$2\"; cat \"$3\"; } | ")) (ELit (LString "{ if command -v sha256sum >/dev/null 2>&1; then sha256sum; ")) (ELit (LString "elif command -v shasum >/dev/null 2>&1; then shasum -a 256; ")) (ELit (LString "else cksum; fi; } | cut -d' ' -f1"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EVar "script") (ELit (LString "sh")) (EVar "cc") (EVar "flagsPath") (EVar "rtC"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EApp (EVar "stringTrim") (EVar "out"))) (arm PWild () (ELit (LString "")))))))))))
(DTypeSig false "cachedRtObj" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "cachedRtObj" ((PVar "cc") (PVar "rtC") (PVar "optFlag") (PVar "gcCflags") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "dir") (EApp (EVar "objCacheDir") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EApp (EApp (EApp (EVar "rtObjCacheKey") (EVar "cc")) (EVar "rtC")) (EVar "optFlag")) (EVar "gcCflags")) (EVar "tmpDir"))) (DoExpr (EIf (EBinOp "==" (EVar "key") (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "objPath") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EBinOp "++" (EBinOp "++" (ELit (LString "rt-")) (EApp (EVar "display") (EVar "key"))) (ELit (LString ".o"))))) (DoLet false false (PVar "hit") (EIf (EApp (EVar "fileExists") (EVar "objPath")) (EApp (EVar "rtObjUsable") (EVar "objPath")) (EVar "False"))) (DoExpr (EIf (EVar "hit") (EVar "objPath") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "populateRtObj") (EVar "cc")) (EVar "rtC")) (EVar "optFlag")) (EVar "gcCflags")) (EVar "dir")) (EVar "objPath"))))))))))))
(DTypeSig false "rtObjUsable" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "rtObjUsable" ((PVar "objPath")) (EBlock (DoLet false false (PVar "script") (EApp (EVar "stringConcat") (EListLit (ELit (LString "command -v nm >/dev/null 2>&1 || exit 0\n")) (ELit (LString "syms=$(nm \"$1\" 2>/dev/null) || exit 1\n")) (ELit (LString "printf '%s\\n' \"$syms\" | grep -qE ' T _?main$'\n"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EVar "script") (ELit (LString "sh")) (EVar "objPath"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))))
(DTypeSig false "populateRtObj" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))))))
(DFunDef false "populateRtObj" ((PVar "cc") (PVar "rtC") (PVar "optFlag") (PVar "gcCflags") (PVar "dir") (PVar "objPath")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mkdir"))) (EListLit (ELit (LString "-p")) (EVar "dir"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mktemp"))) (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "rtobj_XXXXXX"))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "tOut") PWild)) () (EBlock (DoLet false false (PVar "tmpObj") (EApp (EVar "stringTrim") (EVar "tOut"))) (DoExpr (EIf (EBinOp "==" (EVar "tmpObj") (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "ccArgs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcSectionsCflags")) (EVar "gcCflags")) (EListLit (ELit (LString "-c")) (EVar "rtC") (ELit (LString "-o")) (EVar "tmpObj")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EVar "ccArgs")) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mv"))) (EListLit (ELit (LString "-f")) (EVar "tmpObj") (EVar "objPath"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EVar "objPath")) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EVar "tmpObj"))) (DoExpr (ELit (LString ""))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EVar "tmpObj"))) (DoExpr (ELit (LString "")))))))))))) (arm PWild () (ELit (LString ""))))) (arm PWild () (ELit (LString "")))))
(DTypeSig false "rtObjNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "rtObjNote" ((PVar "rtObjEnv") (PVar "rtCached")) (EIf (EBinOp "&&" (EBinOp "/=" (EVar "rtObjEnv") (ELit (LString ""))) (EBinOp "==" (EVar "rtCached") (EVar "rtObjEnv"))) (ELit (LString "MEDAKA_RT_OBJ (explicit)")) (EIf (EBinOp "==" (EVar "rtCached") (ELit (LString ""))) (ELit (LString "inline (no cache)")) (EBinOp "++" (EBinOp "++" (ELit (LString "cache ")) (EApp (EVar "display") (EVar "rtCached"))) (ELit (LString ""))))))
(DTypeSig false "clangLinkGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "BuildResult"))))))))))
(DFunDef false "clangLinkGo" ((PVar "cc") (PVar "rtC") (PVar "llPath") (PVar "outPath") (PVar "inputAbs") (PVar "tmpDir") (PVar "libFlags")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clangLinkTimed") (EVar "cc")) (EVar "rtC")) (EVar "llPath")) (EVar "outPath")) (EVar "inputAbs")) (EVar "tmpDir")) (EVar "libFlags")) (EApp (EVar "perfEnabled") (ELit LUnit))) (EApp (EVar "now") (ELit LUnit))))
(DTypeSig false "clangLinkTimed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "BuildResult"))))))))))))
(DFunDef false "clangLinkTimed" ((PVar "cc") (PVar "rtC") (PVar "llPath") (PVar "outPath") (PVar "inputAbs") (PVar "tmpDir") (PVar "libFlags") (PVar "perfOn") (PVar "tLink0")) (EMatch (EApp (EApp (EVar "detectGC") (EVar "cc")) (EVar "tmpDir")) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config")))) (arm (PCon "Some" (PTuple (PVar "gcCflags") (PVar "gcLibs"))) () (EBlock (DoLet false false (PVar "tGcProbe") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "gc-probe"))) (EBinOp "-" (EVar "tGcProbe") (EVar "tLink0"))) (EVar "cc"))) (DoLet false false (PVar "optFlag") (EVar "clangOptFlag")) (DoLet false false (PVar "rtObjEnv") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_RT_OBJ"))) (ELit (LString "")))) (DoLet false false (PVar "rtCached") (EIf (EBinOp "&&" (EBinOp "/=" (EVar "rtObjEnv") (ELit (LString ""))) (EApp (EVar "fileExists") (EVar "rtObjEnv"))) (EVar "rtObjEnv") (EApp (EApp (EApp (EApp (EApp (EVar "cachedRtObj") (EVar "cc")) (EVar "rtC")) (EVar "optFlag")) (EVar "gcCflags")) (EVar "tmpDir")))) (DoLet false false (PVar "rtInput") (EIf (EBinOp "==" (EVar "rtCached") (ELit (LString ""))) (EVar "rtC") (EVar "rtCached"))) (DoLet false false (PVar "tRtObj") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "rt-obj"))) (EBinOp "-" (EVar "tRtObj") (EVar "tGcProbe"))) (EApp (EApp (EVar "rtObjNote") (EVar "rtObjEnv")) (EVar "rtCached")))) (DoLet false false (PVar "preludeObj") (EApp (EVar "preludeObjOf") (ELit LUnit))) (DoLet false false (PVar "objInputs") (EIf (EBinOp "==" (EVar "preludeObj") (ELit (LString ""))) (EListLit (EVar "llPath") (EVar "rtInput")) (EListLit (EVar "llPath") (EVar "preludeObj") (EVar "rtInput")))) (DoLet false false (PVar "sectionsLink") (EApp (EVar "gcSectionsLinkFlag") (ELit LUnit))) (DoLet false false (PVar "clangArgs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcSectionsCflags")) (EVar "gcCflags")) (EVar "objInputs")) (EVar "libFlags")) (EVar "gcLibs")) (EListLit (EVar "sectionsLink") (ELit (LString "-lm")) (ELit (LString "-o")) (EVar "outPath")))) (DoLet false false (PVar "ccRes") (EApp (EApp (EVar "runCommand") (EVar "cc")) (EVar "clangArgs"))) (DoLet false false (PVar "tClang") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "clang"))) (EBinOp "-" (EVar "tClang") (EVar "tRtObj"))) (EVar "inputAbs"))) (DoExpr (EMatch (EVar "ccRes") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run clang (")) (EApp (EVar "display") (EVar "cc"))) (ELit (LString "): "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "built ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString " -> "))) (EApp (EVar "display") (EVar "outPath"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "ccErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: clang failed linking ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "ccErr"))) (ELit (LString "")))))))))))
(DTypeSig false "preludeObjOf" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "preludeObjOf" (PWild) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_PRELUDE_OBJ"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "p") (ELit (LString ""))) (EApp (EVar "fileExists") (EVar "p"))) (EVar "p") (ELit (LString ""))))))
(DTypeSig false "withEmitHalf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "withEmitHalf" ((PVar "half") (PVar "prog") (PVar "args")) (ETuple (ELit (LString "env")) (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_EMIT_HALF=")) (EApp (EVar "display") (EVar "half"))) (ELit (LString ""))) (EVar "prog")) (EVar "args"))))
(DTypeSig true "emitPreludeObj" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult")))))))
(DFunDef false "emitPreludeObj" ((PVar "cc") (PVar "root") (PVar "medaka") (PVar "outObjPath")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the prelude compile: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EVar "emitPreludeObjIn") (EVar "cc")) (EVar "root")) (EVar "medaka")) (EVar "outObjPath")) (EVar "tmpDir"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
(DTypeSig false "emitPreludeObjIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult"))))))))
(DFunDef false "emitPreludeObjIn" ((PVar "cc") (PVar "root") (PVar "medaka") (PVar "outObjPath") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "detectGC") (EVar "cc")) (EVar "tmpDir")) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config")))) (arm (PCon "Some" (PTuple (PVar "gcCflags") (PVar "_gcLibs"))) () (EBlock (DoLet false false (PVar "stubPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "prelude_entry.mdk")))) (DoLet false false (PVar "llPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "prelude.ll")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "stubPath")) (ELit (LString "main = ()\n"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not write the prelude-object entry stub: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "emitter") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler/entries/llvm_emit_modules_main.mdk")))) (DoLet false false (PVar "emitArgsBase") (EListLit (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk"))) (EVar "stubPath") (EVar "tmpDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib"))))) (DoLet false false (PVar "emitter2") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EVar "defaultMedakaEmitter"))) (DoLet false false (PVar "useNative") (EBinOp "/=" (EVar "emitter2") (ELit (LString "")))) (DoLet false false (PVar "emitProg0") (EIf (EVar "useNative") (EVar "emitter2") (EVar "medaka"))) (DoLet false false (PVar "emitArgs0") (EIf (EVar "useNative") (EVar "emitArgsBase") (EBinOp "::" (ELit (LString "run")) (EBinOp "::" (EVar "emitter") (EVar "emitArgsBase"))))) (DoLet false false (PTuple (PVar "emitProg") (PVar "emitArgs")) (EApp (EApp (EApp (EVar "withEmitHalf") (ELit (LString "prelude"))) (EVar "emitProg0")) (EVar "emitArgs0"))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "emitProg")) (EVar "emitArgs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run emitter (")) (EApp (EVar "display") (EVar "emitProg"))) (ELit (LString "): "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "irRaw") (PVar "emitErr"))) () (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter failed emitting the prelude object\n")) (EApp (EVar "display") (EVar "emitErr"))) (ELit (LString "")))) (EBlock (DoLet false false (PVar "ir") (EApp (EVar "stripTrailingUnit") (EVar "irRaw"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "ir")) (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter produced empty IR for the prelude object\n")) (EApp (EVar "display") (EVar "emitErr"))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "llPath")) (EVar "ir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not write prelude IR: ")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "optFlag") (EVar "clangOptFlag")) (DoLet false false (PVar "ccArgs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcSectionsCflags")) (EVar "gcCflags")) (EListLit (ELit (LString "-c")) (EVar "llPath") (ELit (LString "-o")) (EVar "outObjPath")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EVar "ccArgs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run clang (")) (EApp (EVar "display") (EVar "cc"))) (ELit (LString "): "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "compiled prelude object -> ")) (EApp (EVar "display") (EVar "outObjPath"))) (ELit (LString ""))) (EApp (EVar "emitStderrNote") (EVar "emitErr"))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "ccErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: clang failed compiling the prelude object\n")) (EApp (EVar "display") (EVar "ccErr"))) (ELit (LString "")))))))))))))))))))))))))
(DTypeSig true "emitRtObj" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult"))))))
(DFunDef false "emitRtObj" ((PVar "cc") (PVar "root") (PVar "outObjPath")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the runtime compile: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EMatch (EApp (EApp (EVar "detectGC") (EVar "cc")) (EVar "tmpDir")) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config")))) (arm (PCon "Some" (PTuple (PVar "gcCflags") (PVar "_gcLibs"))) () (EBlock (DoLet false false (PVar "optFlag") (EVar "clangOptFlag")) (DoLet false false (PVar "rtC") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "runtime/medaka_rt.c")))) (DoLet false false (PVar "ccArgs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcSectionsCflags")) (EVar "gcCflags")) (EListLit (ELit (LString "-c")) (EVar "rtC") (ELit (LString "-o")) (EVar "outObjPath")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EVar "ccArgs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run clang (")) (EApp (EVar "display") (EVar "cc"))) (ELit (LString "): "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (ELit (LString "compiled runtime object -> ")) (EApp (EVar "display") (EVar "outObjPath"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "ccErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: clang failed compiling runtime object\n")) (EApp (EVar "display") (EVar "ccErr"))) (ELit (LString ""))))))))))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "stringTrim" false) (mem "joinWith" false))))
(DUse false (UseGroup ("string") ((mem "words" false))))
(DUse false (UseGroup ("support" "timer") ((mem "perfEnabled" false) (mem "now" false) (mem "emitPhase" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false) (mem "findProjectRootOrSelf" false) (mem "readForeignLibs" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "chopExt" false) (mem "joinPath" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false))))
(DUse false (UseGroup ("frontend" "parse_cache") ((mem "notePreludeParse" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "parseErrDiag" false) (mem "ppDiagCliSrc" false))))
(DData Public "BuildResult" () ((variant "BuildOk" (ConPos (TyCon "String"))) (variant "BuildErr" (ConPos (TyCon "String")))) ())
(DData Public "BuildTarget" () ((variant "TNative" (ConPos)) (variant "TWasm" (ConPos))) ())
(DTypeSig false "appendNote" (TyFun (TyCon "String") (TyFun (TyCon "BuildResult") (TyCon "BuildResult"))))
(DFunDef false "appendNote" ((PVar "note") (PCon "BuildOk" (PVar "m"))) (EApp (EVar "BuildOk") (EBinOp "++" (EVar "m") (EVar "note"))))
(DFunDef false "appendNote" ((PVar "note") (PCon "BuildErr" (PVar "m"))) (EApp (EVar "BuildErr") (EBinOp "++" (EVar "m") (EVar "note"))))
(DTypeSig true "envOr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "envOr" ((PVar "name") (PVar "dflt")) (EMatch (EApp (EVar "getEnv") (EVar "name")) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EVar "dflt") (EVar "v"))) (arm (PCon "None") () (EVar "dflt"))))
(DTypeSig true "exeDir" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "exeDir" () (EApp (EVar "dirOf") (EApp (EVar "executablePath") (ELit LUnit))))
(DTypeSig true "defaultMedakaRoot" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "defaultMedakaRoot" () (EVar "exeDir"))
(DTypeSig true "defaultMedakaEmitter" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "defaultMedakaEmitter" () (EApp (EApp (EVar "joinPath") (EVar "exeDir")) (ELit (LString "medaka_emitter"))))
(DTypeSig true "readPreludeFile" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "readPreludeFile" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: cannot read the stdlib prelude at \"")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "\" ("))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ")\n  set MEDAKA_ROOT to your medaka repo/install root, run from the project root, or place stdlib/ next to the medaka binary"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "pe")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path")) (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "pe"))))) (ELit (LString "\n  (while loading the implicit prelude)"))))) (arm (PCon "Ok" (PVar "decls")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "notePreludeParse") (EVar "src")) (EVar "decls"))) (DoExpr (EApp (EVar "Ok") (EVar "src")))))))))
(DTypeSig false "stripTrailingUnit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripTrailingUnit" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 3)))) (EVar "n")) (EVar "s")) (ELit (LString "()\n")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 3)))) (EVar "s")) (EVar "s")))))
(DTypeSig true "makeTempDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "makeTempDir" (PWild) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (ELit (LString "/tmp/medaka_build_XXXXXX")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "dir") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "mktemp -d printed no path"))) (EApp (EVar "Ok") (EVar "dir")))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "mtErr"))) () (EBlock (DoLet false false (PVar "msg") (EApp (EVar "stringTrim") (EVar "mtErr"))) (DoExpr (EApp (EVar "Err") (EIf (EBinOp "==" (EVar "msg") (ELit (LString ""))) (ELit (LString "mktemp -d failed")) (EVar "msg"))))))))
(DTypeSig false "removeEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "removeEntries" (PWild (PList)) (ELit LUnit))
(DFunDef false "removeEntries" ((PVar "dir") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "n")))) (DoExpr (EApp (EApp (EVar "removeEntries") (EVar "dir")) (EVar "rest")))))
(DTypeSig true "cleanupTempDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "cleanupTempDir" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "entries")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "removeEntries") (EVar "dir")) (EVar "entries"))) (DoLet false false PWild (EApp (EVar "removeDir") (EVar "dir"))) (DoExpr (ELit LUnit))))))
(DTypeSig false "sweepStaleTempDirs" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "sweepStaleTempDirs" (PWild) (EBlock (DoLet false false (PVar "findArgs") (EListLit (ELit (LString "/tmp")) (ELit (LString "-maxdepth")) (ELit (LString "1")) (ELit (LString "-type")) (ELit (LString "d")) (ELit (LString "-name")) (ELit (LString "medaka_build_*")) (ELit (LString "-mmin")) (ELit (LString "+360")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "find"))) (EVar "findArgs")) (arm (PCon "Ok" (PTuple PWild (PVar "out") PWild)) () (EApp (EVar "sweepEachStale") (EApp (EVar "words") (EVar "out")))) (arm (PCon "Err" PWild) () (ELit LUnit))))))
(DTypeSig false "sweepEachStale" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "sweepEachStale" ((PList)) (ELit LUnit))
(DFunDef false "sweepEachStale" ((PCons (PVar "d") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "d"))) (DoExpr (EApp (EVar "sweepEachStale") (EVar "rest")))))
(DTypeSig false "detectGC" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGC" ((PVar "cc") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--exists")) (ELit (LString "bdw-gc")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EBlock (DoLet false false (PVar "cflags") (EApp (EApp (EVar "gcQuery") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--cflags")) (ELit (LString "bdw-gc"))))) (DoLet false false (PVar "libs") (EApp (EApp (EVar "gcQuery") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--libs")) (ELit (LString "bdw-gc"))))) (DoExpr (EApp (EVar "Some") (ETuple (EApp (EVar "words") (EVar "cflags")) (EApp (EVar "words") (EVar "libs"))))))) (arm PWild () (EApp (EApp (EVar "detectGCBrew") (EVar "cc")) (EVar "tmpDir")))))
(DTypeSig false "gcQuery" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "gcQuery" ((PVar "prog") (PVar "args")) (EMatch (EApp (EApp (EVar "runCommand") (EVar "prog")) (EVar "args")) (arm (PCon "Ok" (PTuple PWild (PVar "out") PWild)) () (EApp (EVar "stringTrim") (EVar "out"))) (arm (PCon "Err" PWild) () (ELit (LString "")))))
(DTypeSig false "detectGCBrew" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGCBrew" ((PVar "cc") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "brew"))) (EListLit (ELit (LString "--prefix")) (ELit (LString "bdw-gc")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "prefix") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "prefix") (ELit (LString ""))) (EApp (EVar "fileExists") (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "include/gc.h"))))) (EApp (EVar "Some") (ETuple (EListLit (EBinOp "++" (ELit (LString "-I")) (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "include"))))) (EListLit (EBinOp "++" (ELit (LString "-L")) (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "lib")))) (ELit (LString "-lgc"))))) (EApp (EApp (EVar "detectGCBare") (EVar "cc")) (EVar "tmpDir")))))) (arm PWild () (EApp (EApp (EVar "detectGCBare") (EVar "cc")) (EVar "tmpDir")))))
(DTypeSig false "detectGCBare" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGCBare" ((PVar "cc") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "probe") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "gcprobe.c")))) (DoLet false false (PVar "probeOut") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "gcprobe.out")))) (DoLet false false PWild (EApp (EApp (EVar "writeFile") (EVar "probe")) (ELit (LString "#include <gc.h>\nint main(void){return 0;}\n")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EListLit (EVar "probe") (ELit (LString "-lgc")) (ELit (LString "-o")) (EVar "probeOut"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "Some") (ETuple (EListLit) (EListLit (ELit (LString "-lgc")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "gcSectionsCflags" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "gcSectionsCflags" () (EListLit (ELit (LString "-ffunction-sections")) (ELit (LString "-fdata-sections"))))
(DTypeSig false "gcSectionsLinkFlag" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "gcSectionsLinkFlag" (PWild) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "uname"))) (EListLit (ELit (LString "-s")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EVar "out")) (ELit (LString "Darwin"))) (ELit (LString "-Wl,-dead_strip")) (ELit (LString "-Wl,--gc-sections")))) (arm PWild () (ELit (LString "-Wl,--gc-sections")))))
(DTypeSig false "effectiveKeepIr" (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "effectiveKeepIr" ((PVar "cliFlag")) (EBinOp "||" (EVar "cliFlag") (EBinOp "/=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_KEEP_IR"))) (ELit (LString ""))) (ELit (LString "")))))
(DTypeSig false "keepIrNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "keepIrNote" ((PVar "path") (PVar "contents")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "contents")) (arm (PCon "Ok" PWild) () (EBinOp "++" (ELit (LString "\nkept IR: ")) (EVar "path"))) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\nwarning: could not keep IR at ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": "))) (EVar "e")))))
(DTypeSig false "emitStderrNote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "emitStderrNote" ((PVar "emitErr")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "emitErr")) (ELit (LInt 0))) (ELit (LString "")) (EBinOp "++" (ELit (LString "\n")) (EVar "emitErr"))))
(DTypeSig true "runBuild" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))))
(DFunDef false "runBuild" ((PVar "root") (PVar "medaka") (PVar "cc") (PCon "TNative") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EBlock (DoLet false false PWild (EApp (EVar "sweepStaleTempDirs") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNative") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")))))
(DFunDef false "runBuild" ((PVar "root") (PVar "medaka") (PVar "cc") (PCon "TWasm") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EBlock (DoLet false false PWild (EApp (EVar "sweepStaleTempDirs") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runBuildWasm") (EVar "root")) (EVar "medaka")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")))))
(DTypeSig false "runBuildNative" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult")))))))))
(DFunDef false "runBuildNative" ((PVar "root") (PVar "medaka") (PVar "cc") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the build: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeIn") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "inputAbs")) (EVar "outPath")) (EVar "tmpDir")) (EVar "keepIrCli"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
(DTypeSig false "runBuildNativeIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))))
(DFunDef false "runBuildNativeIn" ((PVar "root") (PVar "medaka") (PVar "cc") (PVar "inputAbs") (PVar "outPath") (PVar "tmpDir") (PVar "keepIrCli")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeRoots") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "inputAbs")) (EVar "outPath")) (EVar "tmpDir")) (EVar "keepIrCli")) (EListLit)))
(DTypeSig true "runBuildNativeRoots" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "BuildResult")))))))))))
(DFunDef false "runBuildNativeRoots" ((PVar "root") (PVar "medaka") (PVar "cc") (PVar "inputAbs") (PVar "outPath") (PVar "tmpDir") (PVar "keepIrCli") (PVar "extraRoots")) (EBlock (DoLet false false (PVar "emitter") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler/entries/llvm_emit_modules_main.mdk")))) (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk")))) (DoLet false false (PVar "preludeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk")))) (DoLet false false (PVar "rtC") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "runtime/medaka_rt.c")))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoLet false false (PVar "stdlibDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib")))) (DoLet false false (PVar "inputRoots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "inputAbs"))) (EVar "extraRoots"))) (DoLet false false (PVar "llPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "program.ll")))) (DoLet false false (PVar "emitArgsBase") (EBinOp "++" (EBinOp "++" (EListLit (EVar "runtimeP") (EVar "preludeP") (EVar "inputAbs")) (EVar "inputRoots")) (EListLit (EVar "compilerDir") (EVar "stdlibDir")))) (DoLet false false (PVar "emitter2") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EVar "defaultMedakaEmitter"))) (DoLet false false (PVar "useNative") (EBinOp "/=" (EVar "emitter2") (ELit (LString "")))) (DoLet false false (PVar "emitProg0") (EIf (EVar "useNative") (EVar "emitter2") (EVar "medaka"))) (DoLet false false (PVar "emitArgs0") (EIf (EVar "useNative") (EVar "emitArgsBase") (EBinOp "::" (ELit (LString "run")) (EBinOp "::" (EVar "emitter") (EVar "emitArgsBase"))))) (DoLet false false (PTuple (PVar "emitProg") (PVar "emitArgs")) (EIf (EBinOp "==" (EApp (EVar "preludeObjOf") (ELit LUnit)) (ELit (LString ""))) (ETuple (EVar "emitProg0") (EVar "emitArgs0")) (EApp (EApp (EApp (EVar "withEmitHalf") (ELit (LString "program"))) (EVar "emitProg0")) (EVar "emitArgs0")))) (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "tEmit0") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "emitRes") (EApp (EApp (EVar "runCommand") (EVar "emitProg")) (EVar "emitArgs"))) (DoLet false false (PVar "tEmit1") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "emit-ir"))) (EBinOp "-" (EVar "tEmit1") (EVar "tEmit0"))) (EVar "inputAbs"))) (DoExpr (EMatch (EVar "emitRes") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run emitter (")) (EApp (EMethodRef "display") (EVar "emitProg"))) (ELit (LString "): "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "irRaw") (PVar "emitErr"))) () (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter failed compiling ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "emitErr"))) (ELit (LString "")))) (EBlock (DoLet false false (PVar "ir") (EApp (EVar "stripTrailingUnit") (EVar "irRaw"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "ir")) (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter produced empty IR for ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "emitErr"))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "llPath")) (EVar "ir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not write IR: ")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "ffiRoot") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "dirOf") (EVar "inputAbs")))) (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clangLink") (EVar "cc")) (EVar "rtC")) (EVar "llPath")) (EVar "outPath")) (EVar "inputAbs")) (EVar "tmpDir")) (EVar "ffiRoot")) (EApp (EVar "readForeignLibs") (EVar "ffiRoot")))) (DoLet false false (PVar "note") (EBinOp "++" (EIf (EApp (EVar "effectiveKeepIr") (EVar "keepIrCli")) (EApp (EApp (EVar "keepIrNote") (EBinOp "++" (EVar "outPath") (ELit (LString ".ll")))) (EVar "ir")) (ELit (LString ""))) (EApp (EVar "emitStderrNote") (EVar "emitErr")))) (DoExpr (EApp (EApp (EVar "appendNote") (EVar "note")) (EVar "res")))))))))))))))
(DTypeSig false "runBuildWasm" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))
(DFunDef false "runBuildWasm" ((PVar "root") (PVar "medaka") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the build: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildWasmIn") (EVar "root")) (EVar "medaka")) (EVar "inputAbs")) (EVar "outPath")) (EVar "tmpDir")) (EVar "keepIrCli"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
(DTypeSig false "runBuildWasmIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult")))))))))
(DFunDef false "runBuildWasmIn" ((PVar "root") (PVar "medaka") (PVar "inputAbs") (PVar "outPath") (PVar "tmpDir") (PVar "keepIrCli")) (EBlock (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk")))) (DoLet false false (PVar "preludeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk")))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoLet false false (PVar "stdlibDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib")))) (DoLet false false (PVar "inputRoots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "inputAbs")))) (DoLet false false (PVar "watPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "program.wat")))) (DoLet false false (PVar "emitArgsBase") (EBinOp "++" (EBinOp "++" (EListLit (EVar "runtimeP") (EVar "preludeP") (EVar "inputAbs")) (EVar "inputRoots")) (EListLit (EVar "compilerDir") (EVar "stdlibDir")))) (DoLet false false (PVar "wasmEmitter") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_WASM_EMITTER"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "wasmEmitter") (ELit (LString ""))) (EApp (EVar "BuildErr") (ELit (LString "error: --target wasm needs a compiled wasm emitter — set MEDAKA_WASM_EMITTER to its path\n  build one with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)"))) (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "wasmEmitter"))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: MEDAKA_WASM_EMITTER points to a missing binary: ")) (EApp (EMethodRef "display") (EVar "wasmEmitter"))) (ELit (LString "\n  build it with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)")))) (EMatch (EApp (EVar "probeWasmTools") (ELit LUnit)) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: wasm-tools not found on PATH — install wasm-tools (cargo install wasm-tools or brew install wasm-tools) for --target wasm")))) (arm (PCon "Some" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (EVar "wasmEmitter")) (EVar "emitArgsBase")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run wasm emitter (")) (EApp (EMethodRef "display") (EVar "wasmEmitter"))) (ELit (LString "): "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "watRaw") (PVar "emitErr"))) () (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm emitter failed compiling ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "emitErr"))) (ELit (LString "")))) (EBlock (DoLet false false (PVar "wat") (EApp (EVar "stripTrailingUnit") (EVar "watRaw"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "wat")) (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm emitter produced empty WAT for ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "emitErr"))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "watPath")) (EVar "wat")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not write WAT: ")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EVar "wasmAssemble") (EVar "watPath")) (EVar "outPath")) (EVar "inputAbs"))) (DoLet false false (PVar "note") (EBinOp "++" (EIf (EApp (EVar "effectiveKeepIr") (EVar "keepIrCli")) (EApp (EApp (EVar "keepIrNote") (EBinOp "++" (EVar "outPath") (ELit (LString ".wat")))) (EVar "wat")) (ELit (LString ""))) (EApp (EVar "emitStderrNote") (EVar "emitErr")))) (DoExpr (EApp (EApp (EVar "appendNote") (EVar "note")) (EVar "res")))))))))))))))))))
(DTypeSig false "probeWasmTools" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Unit")))))
(DFunDef false "probeWasmTools" (PWild) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "--version")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "Some") (ELit LUnit))) (arm PWild () (EVar "None"))))
(DTypeSig false "wasmAssemble" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult"))))))
(DFunDef false "wasmAssemble" ((PVar "watPath") (PVar "outPath") (PVar "inputAbs")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "parse")) (EVar "watPath") (ELit (LString "-o")) (EVar "outPath"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not run wasm-tools parse: ")) (EVar "e")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "validate")) (ELit (LString "--features=all")) (EVar "outPath"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not run wasm-tools validate: ")) (EVar "e")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "strip")) (ELit (LString "--all")) (EVar "outPath") (ELit (LString "-o")) (EVar "outPath"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not run wasm-tools strip: ")) (EVar "e")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "built ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EVar "outPath"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "stripErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm-tools strip failed on ")) (EApp (EMethodRef "display") (EVar "outPath"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "stripErr"))) (ELit (LString ""))))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "valErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm-tools validate rejected ")) (EApp (EMethodRef "display") (EVar "outPath"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "valErr"))) (ELit (LString ""))))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "parseErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm-tools parse failed assembling ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "parseErr"))) (ELit (LString "")))))))
(DTypeSig false "clangOptFlag" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "clangOptFlag" () (EBlock (DoLet false false (PVar "optFlagRaw") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_CLANG_OPT"))) (ELit (LString "-O2")))) (DoExpr (EIf (EBinOp "==" (EVar "optFlagRaw") (ELit (LString ""))) (ELit (LString "-O2")) (EVar "optFlagRaw")))))
(DTypeSig false "clangLink" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyEffect ("IO") None (TyCon "BuildResult")))))))))))
(DFunDef false "clangLink" ((PVar "cc") (PVar "rtC") (PVar "llPath") (PVar "outPath") (PVar "inputAbs") (PVar "tmpDir") (PVar "projRoot") (PVar "libs")) (EBlock (DoLet false false (PVar "libErr") (EApp (EApp (EApp (EApp (EVar "foreignLibErr") (EVar "cc")) (EVar "tmpDir")) (EVar "projRoot")) (EVar "libs"))) (DoExpr (EIf (EBinOp "/=" (EVar "libErr") (ELit (LString ""))) (EApp (EVar "BuildErr") (EVar "libErr")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clangLinkGo") (EVar "cc")) (EVar "rtC")) (EVar "llPath")) (EVar "outPath")) (EVar "inputAbs")) (EVar "tmpDir")) (EApp (EVar "libLinkFlags") (EVar "libs")))))))
(DTypeSig false "libLinkFlags" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "libLinkFlags" ((PList)) (EListLit))
(DFunDef false "libLinkFlags" ((PCons (PTuple (PVar "name") (PVar "dir")) (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "-l")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "-L")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "-l")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EVar "libLinkFlags") (EVar "rest"))))))
(DTypeSig false "foreignLibErr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "foreignLibErr" (PWild PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "foreignLibErr" ((PVar "cc") (PVar "tmpDir") (PVar "projRoot") (PVar "libs")) (EBlock (DoLet false false (PVar "probeC") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "ffi_lib_probe.c")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "probeC")) (ELit (LString "int main(void) { return 0; }\n"))) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not write the foreign-library probe source: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (arm (PCon "Ok" PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "foreignLibErrGo") (EVar "cc")) (EVar "tmpDir")) (EVar "projRoot")) (EVar "probeC")) (EVar "libs")))))))
(DTypeSig false "foreignLibErrGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "foreignLibErrGo" (PWild PWild PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "foreignLibErrGo" ((PVar "cc") (PVar "tmpDir") (PVar "projRoot") (PVar "probeC") (PCons (PTuple (PVar "name") (PVar "dir")) (PVar "rest"))) (EBlock (DoLet false false (PVar "probeOut") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "ffi_lib_probe.out")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EBinOp "++" (EListLit (EVar "probeC") (ELit (LString "-o")) (EVar "probeOut")) (EApp (EVar "libLinkFlags") (EListLit (ETuple (EVar "name") (EVar "dir")))))) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run clang (")) (EApp (EMethodRef "display") (EVar "cc"))) (ELit (LString ") to check foreign library '"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "': "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EApp (EApp (EApp (EApp (EVar "foreignLibErrGo") (EVar "cc")) (EVar "tmpDir")) (EVar "projRoot")) (EVar "probeC")) (EVar "rest"))) (arm (PCon "Ok" (PTuple PWild PWild PWild)) () (EApp (EApp (EApp (EVar "missingLibMsg") (EVar "projRoot")) (EVar "name")) (EVar "dir")))))))
(DTypeSig false "missingLibMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "missingLibMsg" ((PVar "projRoot") (PVar "name") (PVar "dir")) (EBlock (DoLet false false (PVar "searched") (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (ELit (LString "the linker's default search path")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString ", nor on the linker's default search path"))))) (DoExpr (EApp (EVar "stringConcat") (EListLit (ELit (LString "error [B-FFI-LIB-NOT-FOUND]: foreign library '")) (EVar "name") (ELit (LString "' was not found in ")) (EVar "searched") (ELit (LString "\n")) (ELit (LString "  declared by the key '")) (EVar "name") (ELit (LString "' under [foreign-libraries] in ")) (EVar "projRoot") (ELit (LString "/medaka.toml\n")) (ELit (LString "  install the library, or point that key at the directory holding it: ")) (EVar "name") (ELit (LString " = \"vendor/lib\"")))))))
(DTypeSig true "objCacheDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "objCacheDir" (PWild) (EIf (EBinOp "/=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_NO_OBJ_CACHE"))) (ELit (LString ""))) (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "explicit") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_CACHE_DIR"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "/=" (EVar "explicit") (ELit (LString ""))) (EVar "explicit") (EBlock (DoLet false false (PVar "xdg") (EApp (EApp (EVar "envOr") (ELit (LString "XDG_CACHE_HOME"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "/=" (EVar "xdg") (ELit (LString ""))) (EApp (EApp (EVar "joinPath") (EVar "xdg")) (ELit (LString "medaka"))) (EBlock (DoLet false false (PVar "home") (EApp (EApp (EVar "envOr") (ELit (LString "HOME"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "home") (ELit (LString ""))) (ELit (LString "")) (EApp (EApp (EVar "joinPath") (EVar "home")) (ELit (LString ".cache/medaka"))))))))))))))
(DTypeSig false "rtObjCacheKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "rtObjCacheKey" ((PVar "cc") (PVar "rtC") (PVar "optFlag") (PVar "gcCflags") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "flagsPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "rtobj_flags")))) (DoLet false false (PVar "flagsText") (EBinOp "++" (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcSectionsCflags")) (EVar "gcCflags"))) (ELit (LString "\n")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "flagsPath")) (EVar "flagsText")) (arm (PCon "Err" PWild) () (ELit (LString ""))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "script") (EApp (EVar "stringConcat") (EListLit (ELit (LString "{ printf '%s\\n' \"$1\"; \"$1\" --version 2>/dev/null; cat \"$2\"; cat \"$3\"; } | ")) (ELit (LString "{ if command -v sha256sum >/dev/null 2>&1; then sha256sum; ")) (ELit (LString "elif command -v shasum >/dev/null 2>&1; then shasum -a 256; ")) (ELit (LString "else cksum; fi; } | cut -d' ' -f1"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EVar "script") (ELit (LString "sh")) (EVar "cc") (EVar "flagsPath") (EVar "rtC"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EApp (EVar "stringTrim") (EVar "out"))) (arm PWild () (ELit (LString "")))))))))))
(DTypeSig false "cachedRtObj" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "cachedRtObj" ((PVar "cc") (PVar "rtC") (PVar "optFlag") (PVar "gcCflags") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "dir") (EApp (EVar "objCacheDir") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EApp (EApp (EApp (EVar "rtObjCacheKey") (EVar "cc")) (EVar "rtC")) (EVar "optFlag")) (EVar "gcCflags")) (EVar "tmpDir"))) (DoExpr (EIf (EBinOp "==" (EVar "key") (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "objPath") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EBinOp "++" (EBinOp "++" (ELit (LString "rt-")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ".o"))))) (DoLet false false (PVar "hit") (EIf (EApp (EVar "fileExists") (EVar "objPath")) (EApp (EVar "rtObjUsable") (EVar "objPath")) (EVar "False"))) (DoExpr (EIf (EVar "hit") (EVar "objPath") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "populateRtObj") (EVar "cc")) (EVar "rtC")) (EVar "optFlag")) (EVar "gcCflags")) (EVar "dir")) (EVar "objPath"))))))))))))
(DTypeSig false "rtObjUsable" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "rtObjUsable" ((PVar "objPath")) (EBlock (DoLet false false (PVar "script") (EApp (EVar "stringConcat") (EListLit (ELit (LString "command -v nm >/dev/null 2>&1 || exit 0\n")) (ELit (LString "syms=$(nm \"$1\" 2>/dev/null) || exit 1\n")) (ELit (LString "printf '%s\\n' \"$syms\" | grep -qE ' T _?main$'\n"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EVar "script") (ELit (LString "sh")) (EVar "objPath"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))))
(DTypeSig false "populateRtObj" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))))))
(DFunDef false "populateRtObj" ((PVar "cc") (PVar "rtC") (PVar "optFlag") (PVar "gcCflags") (PVar "dir") (PVar "objPath")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mkdir"))) (EListLit (ELit (LString "-p")) (EVar "dir"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mktemp"))) (EListLit (EApp (EApp (EVar "joinPath") (EVar "dir")) (ELit (LString "rtobj_XXXXXX"))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "tOut") PWild)) () (EBlock (DoLet false false (PVar "tmpObj") (EApp (EVar "stringTrim") (EVar "tOut"))) (DoExpr (EIf (EBinOp "==" (EVar "tmpObj") (ELit (LString ""))) (ELit (LString "")) (EBlock (DoLet false false (PVar "ccArgs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcSectionsCflags")) (EVar "gcCflags")) (EListLit (ELit (LString "-c")) (EVar "rtC") (ELit (LString "-o")) (EVar "tmpObj")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EVar "ccArgs")) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mv"))) (EListLit (ELit (LString "-f")) (EVar "tmpObj") (EVar "objPath"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EVar "objPath")) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EVar "tmpObj"))) (DoExpr (ELit (LString ""))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EVar "tmpObj"))) (DoExpr (ELit (LString "")))))))))))) (arm PWild () (ELit (LString ""))))) (arm PWild () (ELit (LString "")))))
(DTypeSig false "rtObjNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "rtObjNote" ((PVar "rtObjEnv") (PVar "rtCached")) (EIf (EBinOp "&&" (EBinOp "/=" (EVar "rtObjEnv") (ELit (LString ""))) (EBinOp "==" (EVar "rtCached") (EVar "rtObjEnv"))) (ELit (LString "MEDAKA_RT_OBJ (explicit)")) (EIf (EBinOp "==" (EVar "rtCached") (ELit (LString ""))) (ELit (LString "inline (no cache)")) (EBinOp "++" (EBinOp "++" (ELit (LString "cache ")) (EApp (EMethodRef "display") (EVar "rtCached"))) (ELit (LString ""))))))
(DTypeSig false "clangLinkGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "BuildResult"))))))))))
(DFunDef false "clangLinkGo" ((PVar "cc") (PVar "rtC") (PVar "llPath") (PVar "outPath") (PVar "inputAbs") (PVar "tmpDir") (PVar "libFlags")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clangLinkTimed") (EVar "cc")) (EVar "rtC")) (EVar "llPath")) (EVar "outPath")) (EVar "inputAbs")) (EVar "tmpDir")) (EVar "libFlags")) (EApp (EVar "perfEnabled") (ELit LUnit))) (EApp (EVar "now") (ELit LUnit))))
(DTypeSig false "clangLinkTimed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "BuildResult"))))))))))))
(DFunDef false "clangLinkTimed" ((PVar "cc") (PVar "rtC") (PVar "llPath") (PVar "outPath") (PVar "inputAbs") (PVar "tmpDir") (PVar "libFlags") (PVar "perfOn") (PVar "tLink0")) (EMatch (EApp (EApp (EVar "detectGC") (EVar "cc")) (EVar "tmpDir")) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config")))) (arm (PCon "Some" (PTuple (PVar "gcCflags") (PVar "gcLibs"))) () (EBlock (DoLet false false (PVar "tGcProbe") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "gc-probe"))) (EBinOp "-" (EVar "tGcProbe") (EVar "tLink0"))) (EVar "cc"))) (DoLet false false (PVar "optFlag") (EVar "clangOptFlag")) (DoLet false false (PVar "rtObjEnv") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_RT_OBJ"))) (ELit (LString "")))) (DoLet false false (PVar "rtCached") (EIf (EBinOp "&&" (EBinOp "/=" (EVar "rtObjEnv") (ELit (LString ""))) (EApp (EVar "fileExists") (EVar "rtObjEnv"))) (EVar "rtObjEnv") (EApp (EApp (EApp (EApp (EApp (EVar "cachedRtObj") (EVar "cc")) (EVar "rtC")) (EVar "optFlag")) (EVar "gcCflags")) (EVar "tmpDir")))) (DoLet false false (PVar "rtInput") (EIf (EBinOp "==" (EVar "rtCached") (ELit (LString ""))) (EVar "rtC") (EVar "rtCached"))) (DoLet false false (PVar "tRtObj") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "rt-obj"))) (EBinOp "-" (EVar "tRtObj") (EVar "tGcProbe"))) (EApp (EApp (EVar "rtObjNote") (EVar "rtObjEnv")) (EVar "rtCached")))) (DoLet false false (PVar "preludeObj") (EApp (EVar "preludeObjOf") (ELit LUnit))) (DoLet false false (PVar "objInputs") (EIf (EBinOp "==" (EVar "preludeObj") (ELit (LString ""))) (EListLit (EVar "llPath") (EVar "rtInput")) (EListLit (EVar "llPath") (EVar "preludeObj") (EVar "rtInput")))) (DoLet false false (PVar "sectionsLink") (EApp (EVar "gcSectionsLinkFlag") (ELit LUnit))) (DoLet false false (PVar "clangArgs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcSectionsCflags")) (EVar "gcCflags")) (EVar "objInputs")) (EVar "libFlags")) (EVar "gcLibs")) (EListLit (EVar "sectionsLink") (ELit (LString "-lm")) (ELit (LString "-o")) (EVar "outPath")))) (DoLet false false (PVar "ccRes") (EApp (EApp (EVar "runCommand") (EVar "cc")) (EVar "clangArgs"))) (DoLet false false (PVar "tClang") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "clang"))) (EBinOp "-" (EVar "tClang") (EVar "tRtObj"))) (EVar "inputAbs"))) (DoExpr (EMatch (EVar "ccRes") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run clang (")) (EApp (EMethodRef "display") (EVar "cc"))) (ELit (LString "): "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "built ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EVar "outPath"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "ccErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: clang failed linking ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "ccErr"))) (ELit (LString "")))))))))))
(DTypeSig false "preludeObjOf" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "preludeObjOf" (PWild) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_PRELUDE_OBJ"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "&&" (EBinOp "/=" (EVar "p") (ELit (LString ""))) (EApp (EVar "fileExists") (EVar "p"))) (EVar "p") (ELit (LString ""))))))
(DTypeSig false "withEmitHalf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "withEmitHalf" ((PVar "half") (PVar "prog") (PVar "args")) (ETuple (ELit (LString "env")) (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "MEDAKA_EMIT_HALF=")) (EApp (EMethodRef "display") (EVar "half"))) (ELit (LString ""))) (EVar "prog")) (EVar "args"))))
(DTypeSig true "emitPreludeObj" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult")))))))
(DFunDef false "emitPreludeObj" ((PVar "cc") (PVar "root") (PVar "medaka") (PVar "outObjPath")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the prelude compile: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EVar "emitPreludeObjIn") (EVar "cc")) (EVar "root")) (EVar "medaka")) (EVar "outObjPath")) (EVar "tmpDir"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
(DTypeSig false "emitPreludeObjIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult"))))))))
(DFunDef false "emitPreludeObjIn" ((PVar "cc") (PVar "root") (PVar "medaka") (PVar "outObjPath") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "detectGC") (EVar "cc")) (EVar "tmpDir")) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config")))) (arm (PCon "Some" (PTuple (PVar "gcCflags") (PVar "_gcLibs"))) () (EBlock (DoLet false false (PVar "stubPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "prelude_entry.mdk")))) (DoLet false false (PVar "llPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "prelude.ll")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "stubPath")) (ELit (LString "main = ()\n"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not write the prelude-object entry stub: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "emitter") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler/entries/llvm_emit_modules_main.mdk")))) (DoLet false false (PVar "emitArgsBase") (EListLit (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk"))) (EVar "stubPath") (EVar "tmpDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler"))) (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib"))))) (DoLet false false (PVar "emitter2") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EVar "defaultMedakaEmitter"))) (DoLet false false (PVar "useNative") (EBinOp "/=" (EVar "emitter2") (ELit (LString "")))) (DoLet false false (PVar "emitProg0") (EIf (EVar "useNative") (EVar "emitter2") (EVar "medaka"))) (DoLet false false (PVar "emitArgs0") (EIf (EVar "useNative") (EVar "emitArgsBase") (EBinOp "::" (ELit (LString "run")) (EBinOp "::" (EVar "emitter") (EVar "emitArgsBase"))))) (DoLet false false (PTuple (PVar "emitProg") (PVar "emitArgs")) (EApp (EApp (EApp (EVar "withEmitHalf") (ELit (LString "prelude"))) (EVar "emitProg0")) (EVar "emitArgs0"))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "emitProg")) (EVar "emitArgs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run emitter (")) (EApp (EMethodRef "display") (EVar "emitProg"))) (ELit (LString "): "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "irRaw") (PVar "emitErr"))) () (EIf (EBinOp "/=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter failed emitting the prelude object\n")) (EApp (EMethodRef "display") (EVar "emitErr"))) (ELit (LString "")))) (EBlock (DoLet false false (PVar "ir") (EApp (EVar "stripTrailingUnit") (EVar "irRaw"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "ir")) (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter produced empty IR for the prelude object\n")) (EApp (EMethodRef "display") (EVar "emitErr"))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "llPath")) (EVar "ir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not write prelude IR: ")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "optFlag") (EVar "clangOptFlag")) (DoLet false false (PVar "ccArgs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcSectionsCflags")) (EVar "gcCflags")) (EListLit (ELit (LString "-c")) (EVar "llPath") (ELit (LString "-o")) (EVar "outObjPath")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EVar "ccArgs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run clang (")) (EApp (EMethodRef "display") (EVar "cc"))) (ELit (LString "): "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "compiled prelude object -> ")) (EApp (EMethodRef "display") (EVar "outObjPath"))) (ELit (LString ""))) (EApp (EVar "emitStderrNote") (EVar "emitErr"))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "ccErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: clang failed compiling the prelude object\n")) (EApp (EMethodRef "display") (EVar "ccErr"))) (ELit (LString "")))))))))))))))))))))))))
(DTypeSig true "emitRtObj" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult"))))))
(DFunDef false "emitRtObj" ((PVar "cc") (PVar "root") (PVar "outObjPath")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the runtime compile: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EMatch (EApp (EApp (EVar "detectGC") (EVar "cc")) (EVar "tmpDir")) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config")))) (arm (PCon "Some" (PTuple (PVar "gcCflags") (PVar "_gcLibs"))) () (EBlock (DoLet false false (PVar "optFlag") (EVar "clangOptFlag")) (DoLet false false (PVar "rtC") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "runtime/medaka_rt.c")))) (DoLet false false (PVar "ccArgs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcSectionsCflags")) (EVar "gcCflags")) (EListLit (ELit (LString "-c")) (EVar "rtC") (ELit (LString "-o")) (EVar "outObjPath")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EVar "ccArgs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run clang (")) (EApp (EMethodRef "display") (EVar "cc"))) (ELit (LString "): "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (ELit (LString "compiled runtime object -> ")) (EApp (EMethodRef "display") (EVar "outObjPath"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "ccErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: clang failed compiling runtime object\n")) (EApp (EMethodRef "display") (EVar "ccErr"))) (ELit (LString ""))))))))))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
