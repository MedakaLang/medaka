# META
source_lines=64
stages=DESUGAR,MARK
# SOURCE
-- Deterministic per-stage OPERATION counter for the self-hosted pipeline.
--
-- WHY THIS EXISTS (issue #884, epic #880). The perf gate's ALLOCATION arm is
-- deterministic and noise-free but BLIND to a pure O(n^2) SCAN — a List used as a
-- set / map, linear-searched once per element, which is the single most common
-- quadratic introduced into this compiler. The gate's TIME arm can see such a scan,
-- but only above a 200ms floor with min-of-K and a pinned heap, and it physically
-- cannot grade the small stages (mark / desugar / exhaust-guards never clear the
-- floor on any shape). An OP-COUNTER is deterministic like allocation AND sees a
-- pure scan, so it needs no floor / no min-of-K / no heap-pin and grades exactly the
-- stages TIME cannot. This mirrors tools/refindex.mdk's `opCnt`.
--
-- ⚠️ LOAD-BEARING INVARIANT — THE COUNTER IS WRITE-ONLY (identical rule to
-- timer.mdk's `allocBytes` and llvm_emit.mdk's `returnsSelfTableRef`): it is read
-- ONLY by the profiler drivers (profile_main / profile_modules_main, via `opSnap`),
-- NEVER by any compiler pass. `Ref`/`setRef` are typed PURE in stdlib/runtime.mdk
-- (no effect row), so a global counter mutated inside `contains`/`lookupAssoc`
-- (support/util.mdk) keeps their signatures unchanged and is a pure side channel. No
-- pass reads it => the emitted IR for any given input is UNPERTURBED (the
-- byte-identical-when-MEDAKA_PERF-off proof). Keep it that way: `opCounter` and
-- `opCountOn` are module-PRIVATE so nothing outside this module can even read them.
--
-- GATING (Option C, issue #884): `opBump` increments only when `opCountOn` is True,
-- which the driver flips ONCE at entry via `setOpCounting (perfEnabled ())`. Zero
-- write when off — and no `getEnv` (which is <IO>) ever runs inside the hot scan.
--
-- ACYCLIC: this module imports only the prelude and the stdlib's `u64`, so `util ->
-- opcount` adds no cycle (nothing in util's dependency set imports util). NO reset (unlike refindex's
-- `opCnt := 0`) — per-stage counts are read by snapshot-subtract, so the counter is a
-- single cumulative monotone value.

import u64 as U64

-- The cumulative operation counter.  Module-private: read only via `opSnap`.
opCounter : Ref Int
opCounter = Ref 0

-- Whether `opBump` counts.  Default False (off).  Module-private: flipped only via
-- `setOpCounting`.
opCountOn : Ref Bool
opCountOn = Ref False

-- Turn counting on/off.  Called ONCE by a profiler driver at entry with the value of
-- `perfEnabled ()`; never per element (getEnv is <IO> and must stay out of the scan).
export
setOpCounting : Bool -> Unit
setOpCounting b = opCountOn := b

-- Count one operation, but ONLY when counting is on (Option C gating).  Pure-typed:
-- `setRef` carries no effect row, so callers keep their non-<IO> signatures.
export
opBump : Unit -> Unit
opBump () = match !opCountOn
  -- Incremented in `U64`, which wraps and needs no overflow check: `opBump` runs on
  -- every interpreted step, and the check an `Int` `+ 1` carries kept LLVM from
  -- inlining it there (about +12% of the interpreter's instructions per step).
  True => opCounter := U64.toIntTruncating (U64.truncate !opCounter + 1)
  False => ()

-- Read the cumulative counter.  Paired snapshots (before/after a stage) yield that
-- stage's op delta, exactly as timer.mdk's `allocSnap` yields an alloc delta.
export
opSnap : Unit -> Int
opSnap () = !opCounter
# DESUGAR
(DUse false (UseAlias ("u64") "U64"))
(DTypeSig false "opCounter" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "opCounter" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "opCountOn" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "opCountOn" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig true "setOpCounting" (TyFun (TyCon "Bool") (TyCon "Unit")))
(DFunDef false "setOpCounting" ((PVar "b")) (EApp (EApp (EVar "setRef") (EVar "opCountOn")) (EVar "b")))
(DTypeSig true "opBump" (TyFun (TyCon "Unit") (TyCon "Unit")))
(DFunDef false "opBump" ((PLit LUnit)) (EMatch (EUnOp "!" (EVar "opCountOn")) (arm (PCon "True") () (EApp (EApp (EVar "setRef") (EVar "opCounter")) (EApp (EVar "U64.toIntTruncating") (EBinOp "+" (EApp (EVar "U64.truncate") (EUnOp "!" (EVar "opCounter"))) (ELit (LInt 1)))))) (arm (PCon "False") () (ELit LUnit))))
(DTypeSig true "opSnap" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "opSnap" ((PLit LUnit)) (EUnOp "!" (EVar "opCounter")))
# MARK
(DUse false (UseAlias ("u64") "U64"))
(DTypeSig false "opCounter" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "opCounter" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "opCountOn" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "opCountOn" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig true "setOpCounting" (TyFun (TyCon "Bool") (TyCon "Unit")))
(DFunDef false "setOpCounting" ((PVar "b")) (EApp (EApp (EVar "setRef") (EVar "opCountOn")) (EVar "b")))
(DTypeSig true "opBump" (TyFun (TyCon "Unit") (TyCon "Unit")))
(DFunDef false "opBump" ((PLit LUnit)) (EMatch (EUnOp "!" (EVar "opCountOn")) (arm (PCon "True") () (EApp (EApp (EVar "setRef") (EVar "opCounter")) (EApp (EVar "U64.toIntTruncating") (EBinOp "+" (EApp (EVar "U64.truncate") (EUnOp "!" (EVar "opCounter"))) (ELit (LInt 1)))))) (arm (PCon "False") () (ELit LUnit))))
(DTypeSig true "opSnap" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "opSnap" ((PLit LUnit)) (EUnOp "!" (EVar "opCounter")))
