# META
source_lines=220
stages=DESUGAR,MARK
# SOURCE
-- Per-stage wall-clock timing helpers for the self-hosted pipeline.
-- Guarded by the MEDAKA_PERF environment variable: when unset, emitPhase and
-- emitTotal are no-ops, so drivers that import this module produce byte-identical
-- stdout to their un-instrumented counterparts.
--
-- Typical usage in a perf driver:
--   let on  = perfEnabled ()
--   let t0  = now ()
--   let res = ...stage work...
--   let t1  = now ()
--   let _   = emitPhase on "stage" (t1 - t0) "N decls"
--   ...
--   let _   = emitTotal on (tEnd - tStart)
--
-- All timing output goes to stderr so stdout is not disturbed — with ONE
-- documented exception, the sink below: `medaka run --json`'s machine channel
-- IS stderr (its stdout belongs to the user program), so for that single verb
-- this module's premise inverts and stderr is what must stay undisturbed.

-- ── the `run --json` routing sink (C4, docs/ops/CLI-CONFORMANCE.md §4) ──────
-- When ARMED, every `[perf]`/`[stats]` line this module would have written to
-- stderr is BUFFERED instead, and `medaka run --json` folds the buffer into its
-- one JSON envelope as a `perf` array.  Routed, never suppressed
-- ([W-QUIETER]): dropping the lines under `--json` would make `MEDAKA_PERF=1`
-- silently do nothing on the one verb whose channel needed the fix.
--
-- DISARMED by default, so the other fifteen verbs — and `medaka run` without
-- `--json` — write exactly the bytes they wrote before, which is what
-- `diff_compiler_perf_scaling.sh` and `profile_compiler.sh` parse with
-- `awk -F'\t'`.  Only `runRunCmd` arms it, and only under `--json`.
export
perfSinkOn : Ref Bool
perfSinkOn = Ref False

-- Buffered lines, newest first (`takePerfSink` reverses).
perfSinkLines : Ref (List String)
perfSinkLines = Ref []

-- The single routing decision for every line this module emits.  Every emitter
-- below goes through here rather than calling `ePutStrLn` itself, so the sink
-- cannot be half-applied and the line FORMAT stays defined in exactly one place
-- per emitter.
emitTimerLine : String -> <IO> Unit
emitTimerLine line =
  if !perfSinkOn then
    perfSinkLines := line :: !perfSinkLines
  else
    ePutStrLn line

-- Drain the sink, oldest line first.  Draining (rather than peeking) keeps a
-- second read from re-emitting lines the envelope already carries.
export
takePerfSink : Unit -> <e> List String
takePerfSink _ =
  let ls = !perfSinkLines
  perfSinkLines := []
  revLines ls []

revLines : List String -> List String -> List String
revLines [] acc = acc
revLines (x :: xs) acc = revLines xs (x :: acc)

-- Drain the sink to stderr as prose — `flushStaleNoticeProse`'s
-- (`medaka_cli.mdk`) sibling for the OTHER deferred `run --json` notice, and
-- the same shape.  The sink is armed for the whole of `runRunCmd`, but only
-- the paths that reach an envelope emitter drain it there; the error arms
-- exit through `runAbort`, which emits human prose rather than the envelope,
-- so without this call every staged `[perf]` line dies at process exit —
-- `MEDAKA_PERF=1 medaka run --json <file-with-a-compile-error>` silently doing
-- nothing, which is a severity INCREASE ([W-QUIETER]), not a channel choice.
-- Routed on every path, dropped on none.
--
-- A no-op when the sink is empty, which it always is unless BOTH `--json` and
-- `MEDAKA_PERF` are on ⇒ every other invocation stays byte-identical.  Drains
-- (via `takePerfSink`) rather than peeks, so a later envelope on the same run
-- could not re-emit these lines.
export
flushPerfSinkProse : Unit -> <IO> Unit
flushPerfSinkProse _ = putTimerLines (takePerfSink ())

putTimerLines : List String -> <IO> Unit
putTimerLines [] = ()
putTimerLines (l :: ls) =
  let _ = ePutStrLn l
  putTimerLines ls

-- True when MEDAKA_PERF is set to any value in the environment.
export
perfEnabled : Unit -> <IO> Bool
perfEnabled () = match getEnv "MEDAKA_PERF"
  Some _ => True
  None => False

-- True when MEDAKA_STATS is set to any value in the environment.
--
-- Gates the emitter's table-cardinality dump (llvm_emit.mdk's `emitProgram`
-- entry/exit) — issue #542: a source grep for a dispatch/impl table can
-- undercount the real table by 20x-59x, so this reports the number the
-- emitter itself built rather than one reconstructed from source text.
-- SEPARATE from MEDAKA_PERF (timing) and MEDAKA_PERF_WASM (wasm work-gating)
-- — same "set to any value" rule as `perfEnabled`, not `perfWasmEnabled`'s
-- empty-string exception, because this only gates PRINTING, never work.
export
statsEnabled : Unit -> <IO> Bool
statsEnabled () = match getEnv "MEDAKA_STATS"
  Some _ => True
  None => False

-- Emit one named table cardinality to stderr. No-op when on = False.
-- Format: [stats] <label>\t<count>
export
emitStat : Bool -> String -> Int -> <IO> Unit
emitStat False _ _ = ()
emitStat True label count =
  emitTimerLine "[stats] \{label}\t\{intToString count}"

-- Emit a whole list of (label, count) pairs — the call shape
-- `llvm_emit.mdk`'s `emitProgramWithStats` returns. No-op (per element) when
-- on = False.
export
emitStats : Bool -> List (String, Int) -> <IO> Unit
emitStats _ [] = ()
emitStats on ((label, count) :: rest) =
  let _ = emitStat on label count
  emitStats on rest

-- True when MEDAKA_PERF_WASM is set to any value in the environment.
--
-- SEPARATE from perfEnabled, and it gates WORK rather than OUTPUT — that is the
-- whole point. Every other stage is gated only on printing (`emitPhaseAO on ...`),
-- because every other stage is cheap enough to always run. `wasm-emit` is not: it
-- is ~10x llvm_emit and, sampled at the `xref` shape's resolve-driven N=16000, it
-- cost the `gates (types)` shard ~277 s per run and made it the CI critical path
-- at 12 min against engines' 3.7 min.
--
-- ⚠️ A CALLER MUST BRANCH ON THIS, NOT PASS IT TO emitPhaseAO. Medaka is strict, so
-- `emitPhaseAO (perfWasmEnabled ()) "wasm-emit" ... (wasmText cprog)` still RUNS the
-- emission and saves nothing — it only hides the line. See profile_main.mdk.
--
-- ⚠️ EMPTY IS OFF — a DELIBERATE divergence from perfEnabled's "set to any value",
-- and it is not a style quibble. `getEnv` is C `getenv`: a var set to the EMPTY string
-- is SET, so `MEDAKA_PERF_WASM=` reads `Some ""` and the "any value" rule turns it ON.
-- MEASURED, on the obvious shell spelling of the off-switch:
--   MEDAKA_PERF_WASM="" ... profile_main   =>  wasm-emit RAN
-- Under "any value" this stage is on whenever a caller writes the natural
-- `MEDAKA_PERF_WASM="$flag"` with an unset flag — i.e. the off-switch silently fails
-- OPEN, the ~277 s saving evaporates, and the only symptom is a slow shard. An
-- off-switch whose failure mode is "still on, silently" is not an off-switch.
export
perfWasmEnabled : Unit -> <IO> Bool
perfWasmEnabled () = match getEnv "MEDAKA_PERF_WASM"
  Some "" => False
  Some _ => True
  None => False

-- Current wall-clock time in seconds (gettimeofday).
export
now : Unit -> <IO> Float
now () = wallTimeSec ()

-- Emit one timed phase to stderr.  Label, elapsed time (seconds), and an ops
-- string (free-form: "N decls", "runtime+core", etc).  No-op when on = False.
-- Format: [perf] <label>\t<elapsed>s\t<ops>
export
emitPhase : Bool -> String -> Float -> String -> <IO> Unit
emitPhase False _ _ _ = ()
emitPhase True label elapsed ops =
  emitTimerLine "[perf] \{label}\t\{floatToString elapsed}s\t\{ops}"

-- Emit the total pipeline time to stderr.  No-op when on = False.
export
emitTotal : Bool -> Float -> <IO> Unit
emitTotal False _ = ()
emitTotal True elapsed =
  emitTimerLine ("[perf] total\t" ++ floatToString elapsed ++ "s")

-- Count total declarations across a list of (moduleId, decls) pairs.
-- Used by drivers as a cheap proxy for "work units" without modifying stages.
export
totalDecls : List (String, List a) -> Int
totalDecls [] = 0
totalDecls ((_, ds) :: rest) = countList ds + totalDecls rest

countList : List a -> Int
countList [] = 0
countList (_ :: xs) = 1 + countList xs

-- GC-backed allocation snapshot: total bytes allocated since process start.
-- Use paired snapshots to measure per-stage byte allocations.
-- Backed by Gc.allocated_bytes (monotonically increasing float).
export
allocSnap : Unit -> <IO> Float
allocSnap () = allocBytes ()

-- Extended total emit with allocation (four-field format to match emitPhaseAO).
export
emitTotalA : Bool -> Float -> Float -> <IO> Unit
emitTotalA False _ _ = ()
emitTotalA True elapsed allocTotal =
  emitTimerLine
    "[perf] total\t\{floatToString elapsed}s\t\{floatToString (allocTotal / 1048576.0)}MB\t"

-- Extended phase emit that ALSO appends the deterministic per-stage OP-COUNT delta
-- (issue #884) as a trailing TAB-delimited 5th column. Format:
--   [perf] <label>\t<elapsed>s\t<allocMB>MB\t<ops>\t<opDelta>
--
-- ⚠️ The op-delta MUST be its own tab-delimited field. The existing `<ops>` field is
-- FREE-FORM and contains spaces ("N decls", "runtime+core"), so the perf gate's
-- op-arm parses this with `awk -F'\t'` and reads field 5. A whitespace split would
-- land inside `<ops>` and read garbage — see diff_compiler_perf_scaling.sh:ops_from.
--
-- No existing consumer breaks: the gate's TIME/ALLOC arms and profile_compiler.sh
-- read whitespace-split fields 2/3/4, none of which move when a 5th tab-field is
-- appended. `opDelta` is a snapshot-subtract of opcount.opSnap across the stage.
export
emitPhaseAO : Bool -> String -> Float -> Float -> String -> Int -> <IO> Unit
emitPhaseAO False _ _ _ _ _ = ()
emitPhaseAO True label elapsed allocDelta ops opDelta =
  emitTimerLine
    "[perf] \{label}\t\{floatToString elapsed}s\t\{floatToString (allocDelta / 1048576.0)}MB\t\{ops}\t\{intToString opDelta}"
# DESUGAR
(DTypeSig true "perfSinkOn" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "perfSinkOn" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "perfSinkLines" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "perfSinkLines" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "emitTimerLine" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emitTimerLine" ((PVar "line")) (EIf (EUnOp "!" (EVar "perfSinkOn")) (EApp (EApp (EVar "setRef") (EVar "perfSinkLines")) (EBinOp "::" (EVar "line") (EUnOp "!" (EVar "perfSinkLines")))) (EApp (EVar "ePutStrLn") (EVar "line"))))
(DTypeSig true "takePerfSink" (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "takePerfSink" (PWild) (EBlock (DoLet false false (PVar "ls") (EUnOp "!" (EVar "perfSinkLines"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "perfSinkLines")) (EListLit))) (DoExpr (EApp (EApp (EVar "revLines") (EVar "ls")) (EListLit)))))
(DTypeSig false "revLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "revLines" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "revLines" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "revLines") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig true "flushPerfSinkProse" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "flushPerfSinkProse" (PWild) (EApp (EVar "putTimerLines") (EApp (EVar "takePerfSink") (ELit LUnit))))
(DTypeSig false "putTimerLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "putTimerLines" ((PList)) (ELit LUnit))
(DFunDef false "putTimerLines" ((PCons (PVar "l") (PVar "ls"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "l"))) (DoExpr (EApp (EVar "putTimerLines") (EVar "ls")))))
(DTypeSig true "perfEnabled" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "perfEnabled" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_PERF"))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "statsEnabled" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "statsEnabled" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_STATS"))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "emitStat" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitStat" ((PCon "False") PWild PWild) (ELit LUnit))
(DFunDef false "emitStat" ((PCon "True") (PVar "label") (PVar "count")) (EApp (EVar "emitTimerLine") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[stats] ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "count")))) (ELit (LString "")))))
(DTypeSig true "emitStats" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitStats" (PWild (PList)) (ELit LUnit))
(DFunDef false "emitStats" ((PVar "on") (PCons (PTuple (PVar "label") (PVar "count")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitStat") (EVar "on")) (EVar "label")) (EVar "count"))) (DoExpr (EApp (EApp (EVar "emitStats") (EVar "on")) (EVar "rest")))))
(DTypeSig true "perfWasmEnabled" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "perfWasmEnabled" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_PERF_WASM"))) (arm (PCon "Some" (PLit (LString ""))) () (EVar "False")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "now" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Float"))))
(DFunDef false "now" ((PLit LUnit)) (EApp (EVar "wallTimeSec") (ELit LUnit)))
(DTypeSig true "emitPhase" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "emitPhase" ((PCon "False") PWild PWild PWild) (ELit LUnit))
(DFunDef false "emitPhase" ((PCon "True") (PVar "label") (PVar "elapsed") (PVar "ops")) (EApp (EVar "emitTimerLine") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EVar "display") (EVar "ops"))) (ELit (LString "")))))
(DTypeSig true "emitTotal" (TyFun (TyCon "Bool") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitTotal" ((PCon "False") PWild) (ELit LUnit))
(DFunDef false "emitTotal" ((PCon "True") (PVar "elapsed")) (EApp (EVar "emitTimerLine") (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] total\t")) (EApp (EVar "floatToString") (EVar "elapsed"))) (ELit (LString "s")))))
(DTypeSig true "totalDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyVar "a")))) (TyCon "Int")))
(DFunDef false "totalDecls" ((PList)) (ELit (LInt 0)))
(DFunDef false "totalDecls" ((PCons (PTuple PWild (PVar "ds")) (PVar "rest"))) (EBinOp "+" (EApp (EVar "countList") (EVar "ds")) (EApp (EVar "totalDecls") (EVar "rest"))))
(DTypeSig false "countList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "countList" ((PList)) (ELit (LInt 0)))
(DFunDef false "countList" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countList") (EVar "xs"))))
(DTypeSig true "allocSnap" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Float"))))
(DFunDef false "allocSnap" ((PLit LUnit)) (EApp (EVar "allocBytes") (ELit LUnit)))
(DTypeSig true "emitTotalA" (TyFun (TyCon "Bool") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitTotalA" ((PCon "False") PWild PWild) (ELit LUnit))
(DFunDef false "emitTotalA" ((PCon "True") (PVar "elapsed") (PVar "allocTotal")) (EApp (EVar "emitTimerLine") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] total\t")) (EApp (EVar "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EVar "display") (EApp (EVar "floatToString") (EBinOp "/" (EVar "allocTotal") (ELit (LFloat 1048576.0)))))) (ELit (LString "MB\t")))))
(DTypeSig true "emitPhaseAO" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "emitPhaseAO" ((PCon "False") PWild PWild PWild PWild PWild) (ELit LUnit))
(DFunDef false "emitPhaseAO" ((PCon "True") (PVar "label") (PVar "elapsed") (PVar "allocDelta") (PVar "ops") (PVar "opDelta")) (EApp (EVar "emitTimerLine") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EVar "display") (EApp (EVar "floatToString") (EBinOp "/" (EVar "allocDelta") (ELit (LFloat 1048576.0)))))) (ELit (LString "MB\t"))) (EApp (EVar "display") (EVar "ops"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "opDelta")))) (ELit (LString "")))))
# MARK
(DTypeSig true "perfSinkOn" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "perfSinkOn" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "perfSinkLines" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "perfSinkLines" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "emitTimerLine" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emitTimerLine" ((PVar "line")) (EIf (EUnOp "!" (EVar "perfSinkOn")) (EApp (EApp (EVar "setRef") (EVar "perfSinkLines")) (EBinOp "::" (EVar "line") (EUnOp "!" (EVar "perfSinkLines")))) (EApp (EVar "ePutStrLn") (EVar "line"))))
(DTypeSig true "takePerfSink" (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "takePerfSink" (PWild) (EBlock (DoLet false false (PVar "ls") (EUnOp "!" (EVar "perfSinkLines"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "perfSinkLines")) (EListLit))) (DoExpr (EApp (EApp (EVar "revLines") (EVar "ls")) (EListLit)))))
(DTypeSig false "revLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "revLines" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "revLines" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "revLines") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig true "flushPerfSinkProse" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "flushPerfSinkProse" (PWild) (EApp (EVar "putTimerLines") (EApp (EVar "takePerfSink") (ELit LUnit))))
(DTypeSig false "putTimerLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "putTimerLines" ((PList)) (ELit LUnit))
(DFunDef false "putTimerLines" ((PCons (PVar "l") (PVar "ls"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "l"))) (DoExpr (EApp (EVar "putTimerLines") (EVar "ls")))))
(DTypeSig true "perfEnabled" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "perfEnabled" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_PERF"))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "statsEnabled" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "statsEnabled" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_STATS"))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "emitStat" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitStat" ((PCon "False") PWild PWild) (ELit LUnit))
(DFunDef false "emitStat" ((PCon "True") (PVar "label") (PVar "count")) (EApp (EVar "emitTimerLine") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[stats] ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EDictApp "count")))) (ELit (LString "")))))
(DTypeSig true "emitStats" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitStats" (PWild (PList)) (ELit LUnit))
(DFunDef false "emitStats" ((PVar "on") (PCons (PTuple (PVar "label") (PVar "count")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitStat") (EVar "on")) (EVar "label")) (EDictApp "count"))) (DoExpr (EApp (EApp (EVar "emitStats") (EVar "on")) (EVar "rest")))))
(DTypeSig true "perfWasmEnabled" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "perfWasmEnabled" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_PERF_WASM"))) (arm (PCon "Some" (PLit (LString ""))) () (EVar "False")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "now" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Float"))))
(DFunDef false "now" ((PLit LUnit)) (EApp (EVar "wallTimeSec") (ELit LUnit)))
(DTypeSig true "emitPhase" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "emitPhase" ((PCon "False") PWild PWild PWild) (ELit LUnit))
(DFunDef false "emitPhase" ((PCon "True") (PVar "label") (PVar "elapsed") (PVar "ops")) (EApp (EVar "emitTimerLine") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EMethodRef "display") (EVar "ops"))) (ELit (LString "")))))
(DTypeSig true "emitTotal" (TyFun (TyCon "Bool") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitTotal" ((PCon "False") PWild) (ELit LUnit))
(DFunDef false "emitTotal" ((PCon "True") (PVar "elapsed")) (EApp (EVar "emitTimerLine") (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] total\t")) (EApp (EVar "floatToString") (EVar "elapsed"))) (ELit (LString "s")))))
(DTypeSig true "totalDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyVar "a")))) (TyCon "Int")))
(DFunDef false "totalDecls" ((PList)) (ELit (LInt 0)))
(DFunDef false "totalDecls" ((PCons (PTuple PWild (PVar "ds")) (PVar "rest"))) (EBinOp "+" (EApp (EVar "countList") (EVar "ds")) (EApp (EVar "totalDecls") (EVar "rest"))))
(DTypeSig false "countList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "countList" ((PList)) (ELit (LInt 0)))
(DFunDef false "countList" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countList") (EVar "xs"))))
(DTypeSig true "allocSnap" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Float"))))
(DFunDef false "allocSnap" ((PLit LUnit)) (EApp (EVar "allocBytes") (ELit LUnit)))
(DTypeSig true "emitTotalA" (TyFun (TyCon "Bool") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitTotalA" ((PCon "False") PWild PWild) (ELit LUnit))
(DFunDef false "emitTotalA" ((PCon "True") (PVar "elapsed") (PVar "allocTotal")) (EApp (EVar "emitTimerLine") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] total\t")) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EBinOp "/" (EVar "allocTotal") (ELit (LFloat 1048576.0)))))) (ELit (LString "MB\t")))))
(DTypeSig true "emitPhaseAO" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "emitPhaseAO" ((PCon "False") PWild PWild PWild PWild PWild) (ELit LUnit))
(DFunDef false "emitPhaseAO" ((PCon "True") (PVar "label") (PVar "elapsed") (PVar "allocDelta") (PVar "ops") (PVar "opDelta")) (EApp (EVar "emitTimerLine") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EBinOp "/" (EVar "allocDelta") (ELit (LFloat 1048576.0)))))) (ELit (LString "MB\t"))) (EApp (EMethodRef "display") (EVar "ops"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "opDelta")))) (ELit (LString "")))))
