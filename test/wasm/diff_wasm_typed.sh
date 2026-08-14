#!/usr/bin/env bash
# diff_wasm_typed.sh — Slice W5 differential gate (WASMGC-DESIGN §8, typeclass
# dispatch).  The DISPATCH peer of test/wasm/diff_wasm.sh, mirroring the LLVM split
# (diff_compiler_llvm_typed.sh): the W1–W4 scalar/ADT/closure fixtures stay on the
# PRELUDE-FREE annotate entry (wasm_emit_main, never produces CMethod/CDict); the W5
# DISPATCH fixtures go through the TYPED single-file entry (wasm_emit_typed_main),
# which runs elaborateDict and so DOES produce CMethod/CDict/CImplEntry.
#
# Entry strategy = DUAL-ENTRY (see compiler/entries/wasm_emit_typed_main.mdk header).
# The wholesale modules+DCE switch is NOT usable: DCE retains every prelude
# impl/interface whole (dict-passing dispatch can't prune an impl soundly), so a
# real `medaka build` of even a minimal `Eq Color` fixture emits ~274 prelude impl
# functions (Debug/Display strings, Num Float arith, Char/tuple impls) — all
# out-of-slice WasmGC gaps (W6/W7).  The prelude-free typed fixtures define their own
# minimal interfaces; elaborateDict resolves every route with NO prelude surface.
#
# For each fixture in test/wasm/fixtures_typed/:
#   1. oracle = `./medaka build <fixture>` + run (the OCaml-free native-compiled
#      binary's auto-printed value main — same oracle as diff_wasm.sh).
#   2. emit   = test/bin/wasm_emit_typed_main <runtime.mdk> <fixture>  → WAT
#   3. assemble + validate with wasm-tools; run under Node>=22; diff stdout.
#
# Reports N/M; non-zero exit on any divergence.  Opt-in skip (exit 2) when the
# toolchain (wasm-tools / Node>=22 / clang) is unavailable.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EMITBIN="$ROOT/test/bin/wasm_emit_typed_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/wasm/fixtures_typed"
RUNJS="$ROOT/test/wasm/run.js"
CC="${CC:-clang}"
WASM_SRC="$ROOT/compiler/backend/wasm_emit.mdk"
TYPED_ENTRY="$ROOT/compiler/entries/wasm_emit_typed_main.mdk"

# X-W.H2a structural ratchet. Keep this before every toolchain/binary skip: the
# private program index is source structure, not a capability of wasm-tools.
legacy_state='fnNameSetW|valNameSetW|fnArMapW|implsByMethodW|lazyGlobalMapRef|recFieldsRef|fnsUsedAsValuesRef|fnsUsedAsValuesSetW|ctorArMapW|ctorTyMapW|ctorOrdMapW|typeCtorsMapW'
legacy_installer='installFnIndexW|installImplIndexW|setFnsUsedAsValuesW|installLazyGlobalMapW|installCtorTablesW'
if grep -E "^($legacy_state)[[:space:]]*:" "$WASM_SRC" >/dev/null ||
   grep -E "^($legacy_installer)[[:space:]]*:" "$WASM_SRC" >/dev/null; then
  echo "FAIL wasm typed index ratchet: legacy Wasm state authority remains"
  exit 1
fi
for sym in \
  WasmFnImplIndex WasmRecordValueIndex WasmCtorIndex WasmProgramIndex Prog \
  progIndex makeWasmProgramIndex makeWasmProgramIndexGaps makeWasmProgramIndexWithLazy \
  indexFnNamesW indexValNamesW indexFnAritiesW indexImplsByMethodW indexLazyGlobalsW \
  indexRecFieldsW indexFnsUsedAsValuesW indexCtorAritiesW indexCtorTypesW \
  indexCtorOrdinalsW indexTypeCtorsW; do
  grep -E "^$sym[[:space:]]*:|^data $sym" "$WASM_SRC" >/dev/null || {
    echo "FAIL wasm typed index ratchet: missing private carrier/accessor $sym"
    exit 1
  }
done
gap_legacy_state='gapRecordEnabledW|gapLogW|curGapBindW'
gap_legacy_control='enableGapRecordW|resetGapsW|gapEventsW|setGapBindW'
if grep -E "^($gap_legacy_state)[[:space:]]*:|^export ($gap_legacy_control)[[:space:]]*:" "$WASM_SRC" >/dev/null; then
  echo "FAIL wasm typed gap ratchet: retired gap authority remains"
  exit 1
fi
for sym in WGapMode WasmEmit freshWasmEmit emitProgramRecord; do
  grep -E "^$sym[[:space:]]*:|^data $sym|^export $sym[[:space:]]*:" "$WASM_SRC" >/dev/null || {
    echo "FAIL wasm typed gap ratchet: missing lifecycle carrier/API $sym"
    exit 1
  }
done
grep -F '  | Prog WasmProgramIndex (List String) (List String) Bool (List CImplEntry) WasmEmitInput WasmEmit' "$WASM_SRC" >/dev/null || {
  echo "FAIL wasm typed index ratchet: Prog must retain its index fields plus one WasmEmit field"
  exit 1
}
if grep -E '^(strSegsRef|strSegIdRef)[[:space:]]*:' "$WASM_SRC" >/dev/null; then
  echo "FAIL wasm typed string-state ratchet: retired ambient segment authority remains"
  exit 1
fi
if grep -F 'implSelfCtxRef' "$WASM_SRC" >/dev/null; then
  echo "FAIL wasm typed impl-self-state ratchet: retired ambient authority remains"
  exit 1
fi
if grep -E '^wTrmcCtxRef[[:space:]]*[:=]' "$WASM_SRC" >/dev/null; then
  echo "FAIL H2B6-AUTHORITY-SET: retired trmc authority remains ambient"
  exit 1
fi
for required in \
  'trmcCtx : Ref WTrmcCtx' \
  'trmcCtx = Ref WTrmcOff' \
  'match (progEmit prog).trmcCtx.value' \
  'let saved = (progEmit prog).trmcCtx.value' \
  'let _ = setRef (progEmit prog).trmcCtx (WTrmcOn self arity pslots ctorSet isBuiltinList loopLbl exitLbl)' \
  'let _ = setRef (progEmit prog).trmcCtx saved' \
  'let savedTrmc = (progEmit prog).trmcCtx.value' \
  'let _ = setRef (progEmit prog).trmcCtx WTrmcOff' \
  'let _ = setRef (progEmit prog).trmcCtx savedTrmc'; do
  grep -F -- "$required" "$WASM_SRC" >/dev/null || {
    echo "FAIL H2B6-WTRMC-CARRIER: missing $required"
    exit 1
  }
done
for required in \
  '"--reemit-ref-trap-state"::_' \
  '"--emit-ref-trap-state"::_' \
  'reemitRefTrapState : Unit -> <IO> Unit' \
  'let p1 = emitProgram refTrapStateInput refTrapStateProgram' \
  'let u = emitProgram refTrapStateInput refTrapStateControlProgram' \
  '"REF_TRAP_P2"' \
  'refTrapCtorArities = [("TrapToken", 0)]' \
  'refTrapStateAbortProgram : CProgram'; do
  grep -F -- "$required" "$TYPED_ENTRY" >/dev/null || {
    echo "FAIL H2B8-REF-TRAP-HARNESS: missing $required"
    exit 1
  }
done
[ "$(grep -F 'let body = CLet False PWild (CVar "Pair" AGlobal) (CLet False PWild (CVar "Pair" AGlobal) lambdaBody)' "$TYPED_ENTRY" | wc -l | tr -d '[:space:]')" -eq 1 ] || {
  echo "FAIL H2B7-NAMED-WRAPPER-APPARATUS: lambda fixture must use Pair twice"
  exit 1
}
[ "$(grep -F 'match (progEmit prog).trmcCtx.value' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] || {
  echo "FAIL H2B6-WTRMC-CARRIER: expected exactly two trmc readers"
  exit 1
}
[ "$(grep -F 'let _ = setRef (progEmit prog).trmcCtx WTrmcOff' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] &&
  [ "$(grep -F 'let _ = setRef (progEmit prog).trmcCtx savedTrmc' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] || {
  echo "FAIL H2B6-WTRMC-CLEAR-ROUTES: expected two independent-function clears/restores"
  exit 1
}
grep -F 'emitProgram input cp = emitProgramWith (freshWasmEmit WGapStrict) input cp' "$WASM_SRC" >/dev/null &&
  [ "$(grep -F 'let emit = freshWasmEmit WGapRecord' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] || {
  echo "FAIL H2B6-WTRMC-CLEAR-ROUTES: strict, record, census freshness routes changed"
  exit 1
}
grep -F 'wDispCtxRef' "$WASM_SRC" >/dev/null || {
  echo "FAIL H2B6-WTRMC-CLEAR-ROUTES: nearest-miss wDispCtxRef changed"
  exit 1
}
if grep -E '^(lamIdRef|liftedFnsRef|liftedNamesRef|funcRefsRef|liftedNamesSetW|funcRefsSetW)[[:space:]]*[:=]' "$WASM_SRC" >/dev/null; then
  echo "FAIL H2B7-AUTHORITY-SET: retired lambda authority remains ambient"
  exit 1
fi
for required in \
  'nextLambdaId : Ref Int' \
  'liftedDefinitions : Ref (List (List String))' \
  'liftedDefinitionNames : Ref (OrdMap Unit)' \
  'functionReferences : Ref (List String)' \
  'functionReferenceNames : Ref (OrdMap Unit)' \
  'nextLambdaId = Ref 0' \
  'liftedDefinitions = Ref []' \
  'liftedDefinitionNames = Ref omEmpty' \
  'functionReferences = Ref []' \
  'functionReferenceNames = Ref omEmpty' \
  'freshLamId : WasmEmit -> Int' \
  'addLifted : WasmEmit -> List String -> Unit' \
  'addLiftedNamed : WasmEmit -> String -> List String -> Unit' \
  'noteFuncRef : WasmEmit -> String -> Unit' \
  'emitElemDeclare : WasmEmit -> String' \
  'let n = freshLamId (progEmit prog)' \
  'let gid = freshLamId (progEmit prog)' \
  'addLifted (progEmit prog) (emitLamDefine prog lamName pats captured body)' \
  'addLifted (progEmit prog) def' \
  'let lifted = if progUseClos prog then flatMap (x => x) (reverseL (progEmit prog).liftedDefinitions.value) else []' \
  'let names = "$mdk_pap" :: reverseL emit.functionReferences.value' \
  'emitProgram input cp = emitProgramWith (freshWasmEmit WGapStrict) input cp' \
  'let emit = freshWasmEmit WGapRecord'; do
  grep -F -- "$required" "$WASM_SRC" >/dev/null || {
    echo "FAIL H2B7-CARRIER: missing $required"
    exit 1
  }
done
[ "$(grep -F 'freshLamId (progEmit prog)' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 3 ] || {
  echo "FAIL H2B7-ROUTES: expected three lambda-id routes"
  exit 1
}
[ "$(grep -F 'addLiftedNamed (progEmit prog)' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] &&
  [ "$(grep -F 'noteFuncRef (progEmit prog)' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 6 ] || {
  echo "FAIL H2B7-ROUTES: named lifts or function-reference routes changed"
  exit 1
}
grep -F 'emitScalarProgram emit fnNames valNames groups' "$WASM_SRC" >/dev/null || {
  echo "FAIL H2B7-NEAREST-MISS: scalar emission route changed"
  exit 1
}
if grep -E '^useTrapImport[[:space:]]*[:=]' "$WASM_SRC" >/dev/null; then
  echo "FAIL H2B8-AUTHORITY-SET: retired trap-import authority remains ambient"
  exit 1
fi
for required in \
  'trapImportNeeded : Ref Bool' \
  'trapImportNeeded = Ref False' \
  'wasmTrapBytes : WasmEmit -> String -> List String' \
  'wasmTrap : WasmEmit -> String -> String -> List String' \
  'setRef emit.trapImportNeeded True' \
  'let trapImport = if emit.trapImportNeeded.value then stderrByteImportLines else []' \
  'let trapImport = if useEPutRef.value || (progEmit prog).trapImportNeeded.value then stderrByteImportLines else []' \
  'let _ = setRef (progEmit prog).trapImportNeeded True' \
  'emitDivZeroGuard : WasmEmit -> String -> String -> List String' \
  'emitDivZeroGuard emit op "$__sdivr"' \
  'emitDivZeroGuard (progEmit prog) op ("$__divr" ++ intToString d)' \
  'wasmTrap (progEmit prog) "E-NONEXHAUSTIVE-MATCH" "non-exhaustive match"' \
  'wasmTrapBytes (progEmit prog) "runtime error [E-PANIC]: "'; do
  grep -F -- "$required" "$WASM_SRC" >/dev/null || {
    echo "FAIL H2B8-CARRIER: missing $required"
    exit 1
  }
done
[ "$(grep -F 'let _ = setRef (progEmit prog).trapImportNeeded True' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] || {
  echo "FAIL H2B8-WRITERS: expected two explicit poly-runtime writers"
  exit 1
}
grep -F 'useEPutRef : Ref Bool' "$WASM_SRC" >/dev/null &&
  grep -F 'let stderrRt = if useEPutRef.value then stderrRuntimeLines else []' "$WASM_SRC" >/dev/null || {
  echo "FAIL H2B8-NEAREST-MISS: ePut authority changed"
  exit 1
}
if grep -E '^_?useDivGuardRef[[:space:]]*[:=]|setRef (_?useDivGuardRef)' "$WASM_SRC" >/dev/null; then
  echo "FAIL H2B9-DIV-AUTHORITY: retired ambient divisor authority remains"
  exit 1
fi
if grep -E '^_?useRecUpdateRef[[:space:]]*[:=]|setRef (_?useRecUpdateRef)' "$WASM_SRC" >/dev/null; then
  echo "FAIL H2B9-RECUPDATE-AUTHORITY: retired ambient record-update authority remains"
  exit 1
fi
if grep -E '^_?useRngRef[[:space:]]*[:=]|setRef (_?useRngRef)' "$WASM_SRC" >/dev/null; then
  echo "FAIL H2B9-RNG-AUTHORITY: retired ambient RNG authority remains"
  exit 1
fi
if grep -E '^_?useHashRef[[:space:]]*[:=]|setRef (_?useHashRef)' "$WASM_SRC" >/dev/null; then
  echo "FAIL H2B9-HASH-AUTHORITY: retired ambient hash authority remains"
  exit 1
fi
for required in \
  'useRecUpdate : Ref Bool' \
  'useRecUpdate = Ref' \
  'let ru = if emit.useRecUpdate.value then ["(local $__rub" ++ sfx ++ " (ref eq))"] else []'; do
  grep -F -- "$required" "$WASM_SRC" >/dev/null || {
    echo "FAIL H2B9-RECUPDATE-AUTHORITY: missing $required"
    exit 1
  }
done
for required in \
  'useDivGuard : Ref Bool' \
  'useDivGuard = Ref' \
  'scanProgW7 : WasmEmit -> List CBind -> Unit' \
  'scanImplsW7 : WasmEmit -> List CImplEntry -> Unit' \
  'scanImplEntryW7 : WasmEmit -> CImplEntry -> Unit' \
  'scanBindW7 : WasmEmit -> CBind -> Unit' \
  'scanClauseW7 : WasmEmit -> CClause -> Unit' \
  'scanExprW7 : WasmEmit -> CExpr -> Unit' \
  'scanW7Head : WasmEmit -> CExpr -> Unit' \
  'noteW8Extern : WasmEmit -> String -> Unit' \
  'noteW8Binop : WasmEmit -> String -> Unit' \
  'scanArmW7 : WasmEmit -> CArm -> Unit' \
  'scanGuardW7 : WasmEmit -> CGuard -> Unit' \
  'scanStmtW7 : WasmEmit -> CStmt -> Unit' \
  'scanPatW7 : WasmEmit -> Pat -> Unit' \
  'scanTreeW7 : WasmEmit -> CTree -> Unit' \
  'scanBranchW7 : WasmEmit -> CTBranch -> Unit' \
  'scanHeadW7 : WasmEmit -> CHead -> Unit' \
  'w7LocalDecls : WasmEmit -> Int -> List String' \
  'w7LocalsAtDepth : WasmEmit -> Int -> List String' \
  'noteW8Binop emit "/" = setRef emit.useDivGuard True' \
  'noteW8Binop emit "%" = setRef emit.useDivGuard True' \
  'let dv = if emit.useDivGuard.value then ["    (local $__sdivr i64)"] else []' \
  'let dv = if emit.useDivGuard.value then ["(local $__sdivr i64)"] else []'; do
  grep -F -- "$required" "$WASM_SRC" >/dev/null || {
    echo "FAIL H2B9-DIV-AUTHORITY: missing $required"
    exit 1
  }
done
[ "$(grep -F 'w7LocalDecls (progEmit prog)' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 9 ] || {
  echo "FAIL H2B9-DIV-AUTHORITY: expected nine ref-local declaration callers"
  exit 1
}
[ "$(grep -F 'setRef emit.useRecUpdate True' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] || {
  echo "FAIL H2B9-RECUPDATE-AUTHORITY: expected two update scan writers"
  exit 1
}
grep -F 'scanExprW7 emit (CFieldAccess ex _ _) = scanExprW7 emit ex' "$WASM_SRC" >/dev/null &&
  ! grep -A 1 -F 'scanExprW7 emit (CRecord _ fields) =' "$WASM_SRC" | grep -F 'useRecUpdate' >/dev/null || {
  echo "FAIL H2B9-RECUPDATE-NEAREST-MISS: plain record construction/access changed authority"
  exit 1
}
for required in \
  'useRng : Ref Bool' \
  'useRng = Ref' \
  'useHash : Ref Bool' \
  'useHash = Ref' \
  'noteW8Extern emit name =' \
  'setRef emit.useRng True' \
  'setRef emit.useHash True' \
  '|| emit.useRng.value || emit.useHash.value || useFloatRef.value' \
  'let rngGlobal = if (progEmit prog).useRng.value then rngStateGlobalLines else []' \
  'let rngRt = if (progEmit prog).useRng.value then rngRuntimeLines else []' \
  'let hashRt = if (progEmit prog).useHash.value then hashRuntimeLines else []' \
  'let hashStrRt = if (progEmit prog).useHash.value && useStrRef.value then hashStringRuntimeLines else []' \
  'setRef useFloatHashRef True in setRef emit.useHash True' \
  'setRef useFloatRngRef True in setRef emit.useRng True'; do
  grep -F -- "$required" "$WASM_SRC" >/dev/null || {
    echo "FAIL H2B9-RNG-HASH-AUTHORITY: missing $required"
    exit 1
  }
done
EXPECTED_MODULE_REFS="$(printf '%s\n' \
  useStrRef useListRef useArrayRef useRefBoxRef \
  useStrLeafRef useEPutRef \
  useFloatRef useFloatHashRef useMathRef useFloatRngRef useFloatStrRef \
  useStrSearchRef useValueCmpRef useValueArithRef numPolyLocalsRef useStrCodecRef \
   useCharFromCodeRef useCharClassRef useIORef useArgsRef useFileBytesRef \
   floatLocalsRef floatGlobalsRef tupleAritiesRef wDispCtxRef \
  wDispGroupsRef | LC_ALL=C sort -u)"
ACTUAL_MODULE_REF_SIGS="$(awk '
  /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*Ref([[:space:]]|$)/ { print $1 }
  /^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*Ref([[:space:]]|$)/ { print $2 }
  /^public[[:space:]]+export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*Ref([[:space:]]|$)/ { print $3 }
' "$WASM_SRC" | LC_ALL=C sort -u)"
ACTUAL_MODULE_REF_DEFS="$(awk '
  /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*Ref([[:space:]]|$)/ { print $1 }
  /^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*Ref([[:space:]]|$)/ { print $2 }
  /^public[[:space:]]+export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*Ref([[:space:]]|$)/ { print $3 }
' "$WASM_SRC" | LC_ALL=C sort -u)"
if [ "$ACTUAL_MODULE_REF_SIGS" != "$EXPECTED_MODULE_REFS" ] ||
    [ "$ACTUAL_MODULE_REF_DEFS" != "$EXPECTED_MODULE_REFS" ]; then
  echo "FAIL H2B8-AUTHORITY-SET: top-level Ref authority set changed"
  printf '  observed signatures:\n%s\n' "$ACTUAL_MODULE_REF_SIGS"
  printf '  observed definitions:\n%s\n' "$ACTUAL_MODULE_REF_DEFS"
  exit 1
fi
for required in \
  'currentBinding : Ref String' \
  'currentBinding = Ref "?"' \
  'currentBindingOfW : WasmEmit -> String' \
  'currentBindingOfW emit = emit.currentBinding.value' \
  'setCurrentBindingOfW : WasmEmit -> String -> Unit' \
  'setCurrentBindingOfW emit name = setRef emit.currentBinding name'; do
  [ "$(grep -F -- "$required" "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 1 ] || {
    echo "FAIL H2B5-CARRIER: missing $required"
    exit 1
  }
done
if grep -E '^curBindRef[[:space:]]*[:=]' "$WASM_SRC" >/dev/null; then
  echo "FAIL H2B5-AUTHORITY-SET: retired current-binding authority remains ambient"
  exit 1
fi
[ "$(grep -F 'setCurrentBindingOfW (progEmit prog)' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] || {
  echo "FAIL H2B5-ROUTES: expected exactly two current-binding setter call sites"
  exit 1
}
[ "$(grep -F 'currentBindingOfW (progEmit prog)' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] &&
  [ "$(grep -F '++ currentBindingOfW emit ++' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 1 ] &&
  [ "$(grep -F 'currentBindingOfW' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 5 ] &&
  [ "$(grep -F 'setCurrentBindingOfW' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 4 ] || {
  echo "FAIL H2B5-ROUTES: expected exactly three current-binding getter call sites"
  exit 1
}
grep -F 'patName emit _ =' "$WASM_SRC" >/dev/null &&
  grep -F 'currentBindingOfW emit ++ "]")' "$WASM_SRC" >/dev/null || {
  echo "FAIL H2B5-PATNAME-STRUCTURAL: patName fallback is not routed through WasmEmit"
  exit 1
}
if grep -E 'let (saved|old|prior|previous)[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*currentBindingOfW|setCurrentBindingOfW.*(saved|old|prior|previous)' "$WASM_SRC" >/dev/null; then
  echo "FAIL H2B5-NO-RESTORE: current-binding save/restore is forbidden"
  exit 1
fi
[ "$(grep -F 'emit.currentBinding' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] || {
  echo "FAIL H2B5-NO-RESTORE: current-binding alias/reset/restore route added"
  exit 1
}
for required in \
  'stringSegments : Ref (List (Int, List Int))' \
  'nextStringSegmentId : Ref Int' \
  'freshStrSeg : WasmEmit -> List Int -> Int' \
  'emitDataSegs : WasmEmit -> List String' \
  'emitLitRef : WasmEmit -> Lit -> List String' \
  'implSelfCtx : Ref ImplSelfCtx' \
  'implSelfCtx = Ref ImplSelfOff' \
  'let savedImplSelf = (progEmit prog).implSelfCtx.value' \
  'let _ = setRef (progEmit prog).implSelfCtx (ImplSelfOn method headTag arity)' \
  'let _ = setRef (progEmit prog).implSelfCtx savedImplSelf' \
  'implSelfReturnCall prog env name route methRoutes implRoutes app args = match (progEmit prog).implSelfCtx.value' \
  'let i = emit.nextStringSegmentId.value' \
  'setRef emit.nextStringSegmentId (i + 1)' \
  'setRef emit.stringSegments ((i, bytes)::emit.stringSegments.value)' \
  'reverseL emit.stringSegments.value' \
  'emitProgram input cp = emitProgramWith (freshWasmEmit WGapStrict) input cp' \
  'emitProgramRecord input cp =' \
  'emitProgramGaps input (CProgram groups ctorArs ctorTypes impls) =' \
  'let emit = freshWasmEmit WGapRecord' \
  'let dataSegs = emitDataSegs (progEmit prog)' \
  'emitRefExpr prog env d (CLit l) = emitLitRef (progEmit prog) l'; do
  grep -F -- "$required" "$WASM_SRC" >/dev/null || {
    echo "FAIL wasm typed string-state ratchet: missing $required"
    exit 1
  }
done
for required in \
  '"--reemit-trmc-state"::_' \
  'reemitTrmcState : Unit -> <IO> Unit' \
  'let p1 = emitProgram trmcStateInput (trmcStateProgram "pTrmc" 17)' \
  'let (u, _) = emitProgramRecord trmcStateInput (trmcStateProgram "uTrmc" 29)' \
  'let censusEvents = emitProgramGaps trmcStateInput trmcStateCensusProgram' \
  '"TRMC_P2"' \
  '(emitProgram trmcStateInput (trmcStateProgram "pTrmc" 17))' \
  'CBind "trmcIntentionalGap" [CClause [] (CVar "missingTrmcCensus" AGlobal)]' \
  '"--reemit-impl-self-state"::_' \
  'reemitImplSelfState : Unit -> <IO> Unit' \
  'let p1 = emitProgram implSelfInput pProgram' \
  'let (u, _) = emitProgramRecord implSelfInput uProgram' \
  'let censusEvents = emitProgramGaps implSelfInput (implSelfCensusProgram uProgram)' \
  'printCapture "IMPL_SELF_P2" (emitProgram implSelfInput pProgram)' \
  'printCapture "IMPL_SELF_P1" p1' \
  'printCapture "IMPL_SELF_RECORD_U" u' \
  'printEvents "IMPL_SELF_CENSUS_U_GAP" censusEvents' \
  'implSelfIntentionalGap' \
  'missingImplSelfGap'; do
  grep -F -- "$required" "$TYPED_ENTRY" >/dev/null || {
    echo "FAIL wasm typed impl-self-state ratchet: missing $required"
    exit 1
  }
done
for required in \
  '"--capture-current-binding"::row::_' \
  'captureCurrentBinding : String -> <IO> Unit' \
  'bindingLoc : Loc' \
  'bindingInput : WasmEmitInput' \
  'bindingEventCaptures : String -> CProgram -> <IO> Unit' \
  'bindingUnsupported = CMatch (CLit (LInt 0)) []' \
  'bindingWriterProgram : CProgram' \
  'emitProgram bindingInput bindingNoWriterProgram' \
  'CBIND_TOP_STRICT' \
  'CBIND_LIFT_STRICT' \
  'CBIND_NOWRITER_STRICT' \
  'CBIND_POSTLIFT_STRICT' \
  'CBIND_MALFORMED_REF_ROUTE'; do
  grep -F -- "$required" "$TYPED_ENTRY" >/dev/null || {
    echo "FAIL CBIND-CAPTURE-MARKERS: missing $required"
    exit 1
  }
done
run_impl_self_check() {
  IMPL_SELF_OUT="$($EMITBIN --reemit-impl-self-state 2>"$INPUT_WORK/impl-self.emit.err")" || {
    echo "FAIL wasm typed impl-self-state harness"
    cat "$INPUT_WORK/impl-self.emit.err"
    exit 1
  }
  [ ! -s "$INPUT_WORK/impl-self.emit.err" ] || {
    echo "FAIL wasm typed impl-self-state harness wrote stderr"
    cat "$INPUT_WORK/impl-self.emit.err"
    exit 1
  }
  IMPL_SELF_MARKERS="$(printf '%s\n' "$IMPL_SELF_OUT" | awk '/^IMPL_SELF_(P1|RECORD_U|CENSUS_U_GAP|P2)_(BEGIN|END)$/ { print }')"
  IMPL_SELF_EXPECTED_MARKERS="$(printf 'IMPL_SELF_P1_BEGIN\nIMPL_SELF_P1_END\nIMPL_SELF_RECORD_U_BEGIN\nIMPL_SELF_RECORD_U_END\nIMPL_SELF_CENSUS_U_GAP_BEGIN\nIMPL_SELF_CENSUS_U_GAP_END\nIMPL_SELF_P2_BEGIN\nIMPL_SELF_P2_END')"
  [ "$IMPL_SELF_MARKERS" = "$IMPL_SELF_EXPECTED_MARKERS" ] || {
    echo "FAIL wasm typed impl-self-state lifecycle: expected exactly eight ordered markers"
    exit 1
  }
  impl_self_capture() {
    awk -v begin="$1" -v end="$2" '
      $0 == begin { capture = 1; next }
      $0 == end { exit }
      capture { print }
    ' <<<"$IMPL_SELF_OUT"
  }
  impl_self_capture IMPL_SELF_P1_BEGIN IMPL_SELF_P1_END > "$INPUT_WORK/impl-self-p1.wat"
  impl_self_capture IMPL_SELF_RECORD_U_BEGIN IMPL_SELF_RECORD_U_END > "$INPUT_WORK/impl-self-u.wat"
  impl_self_capture IMPL_SELF_CENSUS_U_GAP_BEGIN IMPL_SELF_CENSUS_U_GAP_END > "$INPUT_WORK/impl-self-census.events"
  impl_self_capture IMPL_SELF_P2_BEGIN IMPL_SELF_P2_END > "$INPUT_WORK/impl-self-p2.wat"
  for impl_self_file in impl-self-p1.wat impl-self-u.wat impl-self-census.events impl-self-p2.wat; do
    [ -s "$INPUT_WORK/$impl_self_file" ] || {
      echo "FAIL wasm typed impl-self-state lifecycle: empty $impl_self_file"
      exit 1
    }
  done
  cmp -s "$INPUT_WORK/impl-self-p1.wat" "$INPUT_WORK/impl-self-p2.wat" || {
    echo "FAIL wasm typed impl-self-state lifecycle: P changed after record U and census"
    exit 1
  }
  cmp -s "$INPUT_WORK/impl-self-p1.wat" "$INPUT_WORK/impl-self-u.wat" && {
    echo "FAIL wasm typed impl-self-state lifecycle: P/U positive control did not differ"
    exit 1
  }
  for impl_self_spec in "p1 PLoop 3" "u ULoop 4" "p2 PLoop 3"; do
    impl_self_name="${impl_self_spec%% *}"
    impl_self_rest="${impl_self_spec#* }"
    impl_self_tag="${impl_self_rest%% *}"
    impl_self_expected="${impl_self_rest#* }"
    impl_self_wat="$INPUT_WORK/impl-self-$impl_self_name.wat"
    [ "$(grep -F "return_call \$mdk_impl_${impl_self_tag}_walk" "$impl_self_wat" | wc -l | tr -d '[:space:]')" -eq 1 ] || {
      echo "FAIL wasm typed impl-self-state lifecycle: $impl_self_name recursive return_call changed"
      exit 1
    }
    [ "$(grep -F "call \$mdk_impl_${impl_self_tag}_walk" "$impl_self_wat" | grep -v 'return_call' | wc -l | tr -d '[:space:]')" -eq 0 ] || {
      echo "FAIL wasm typed impl-self-state lifecycle: $impl_self_name gained plain recursive call"
      exit 1
    }
    wasm-tools parse "$impl_self_wat" -o "$INPUT_WORK/impl-self-$impl_self_name.wasm" || {
      echo "FAIL wasm typed impl-self-state lifecycle: wasm-tools parse $impl_self_name"
      exit 1
    }
    wasm-tools validate --features=all "$INPUT_WORK/impl-self-$impl_self_name.wasm" || {
      echo "FAIL wasm typed impl-self-state lifecycle: wasm-tools validate $impl_self_name"
      exit 1
    }
    IMPL_SELF_RESULT="$($NODE "$RUNJS" "$INPUT_WORK/impl-self-$impl_self_name.wasm" 2>"$INPUT_WORK/impl-self-$impl_self_name.run.err")" || {
      echo "FAIL wasm typed impl-self-state lifecycle: execution failed for $impl_self_name"
      cat "$INPUT_WORK/impl-self-$impl_self_name.run.err"
      exit 1
    }
    [ ! -s "$INPUT_WORK/impl-self-$impl_self_name.run.err" ] && [ "$IMPL_SELF_RESULT" = "$impl_self_expected" ] || {
      echo "FAIL wasm typed impl-self-state lifecycle: execution changed for $impl_self_name"
      exit 1
    }
  done
  [ "$(wc -l < "$INPUT_WORK/impl-self-census.events")" -eq 1 ] &&
    grep -F $'val implSelfIntentionalGap\tunbound variable '\''missingImplSelfGap' "$INPUT_WORK/impl-self-census.events" >/dev/null || {
      echo "FAIL wasm typed impl-self-state lifecycle: census event changed"
      exit 1
    }
}

run_trmc_state_check() {
  TRMC_OUT="$($EMITBIN --reemit-trmc-state 2>"$INPUT_WORK/trmc.emit.err")" || {
    echo "FAIL H2B6-WTRMC-P-SHAPE: trmc state harness"
    cat "$INPUT_WORK/trmc.emit.err"
    exit 1
  }
  [ ! -s "$INPUT_WORK/trmc.emit.err" ] || {
    echo "FAIL H2B6-WTRMC-P-SHAPE: trmc harness wrote stderr"
    cat "$INPUT_WORK/trmc.emit.err"
    exit 1
  }
  TRMC_MARKERS="$(printf '%s\n' "$TRMC_OUT" | awk '/^TRMC_(P1|RECORD_U|CENSUS_U_GAP|P2)_(BEGIN|END)$/ { print }')"
  TRMC_EXPECTED_MARKERS="$(printf 'TRMC_P1_BEGIN\nTRMC_P1_END\nTRMC_RECORD_U_BEGIN\nTRMC_RECORD_U_END\nTRMC_CENSUS_U_GAP_BEGIN\nTRMC_CENSUS_U_GAP_END\nTRMC_P2_BEGIN\nTRMC_P2_END')"
  [ "$TRMC_MARKERS" = "$TRMC_EXPECTED_MARKERS" ] || {
    echo "FAIL H2B6-WTRMC-P-SHAPE: ordered capture markers"
    exit 1
  }
  trmc_capture() {
    awk -v begin="$1" -v end="$2" '
      $0 == begin { capture = 1; next }
      $0 == end { exit }
      capture { print }
    ' <<<"$TRMC_OUT"
  }
  trmc_capture TRMC_P1_BEGIN TRMC_P1_END > "$INPUT_WORK/trmc-p1.wat"
  trmc_capture TRMC_RECORD_U_BEGIN TRMC_RECORD_U_END > "$INPUT_WORK/trmc-u.wat"
  trmc_capture TRMC_CENSUS_U_GAP_BEGIN TRMC_CENSUS_U_GAP_END > "$INPUT_WORK/trmc-census.events"
  trmc_capture TRMC_P2_BEGIN TRMC_P2_END > "$INPUT_WORK/trmc-p2.wat"
  trmc_named_body() {
    awk -v name="$1" '
      $0 ~ "\\(func \\$" name "( |\\))" { take = 1 }
      take {
        print
        opens = gsub(/\(/, "(")
        closes = gsub(/\)/, ")")
        depth += opens - closes
        if (depth == 0) exit
      }
    ' "$2"
  }
  for trmc_file in trmc-p1.wat trmc-u.wat trmc-census.events trmc-p2.wat; do
    [ -s "$INPUT_WORK/$trmc_file" ] || {
      echo "FAIL H2B6-WTRMC-P-SHAPE: empty $trmc_file"
      exit 1
    }
  done
  cmp -s "$INPUT_WORK/trmc-p1.wat" "$INPUT_WORK/trmc-p2.wat" || {
    echo "FAIL H2B6-WTRMC-P-SHAPE: P changed after record U and census"
    exit 1
  }
  cmp -s "$INPUT_WORK/trmc-p1.wat" "$INPUT_WORK/trmc-u.wat" && {
    echo "FAIL H2B6-WTRMC-P-SHAPE: P/U positive control did not differ"
    exit 1
  }
  for trmc_spec in "p1 pTrmc 17" "u uTrmc 29" "p2 pTrmc 17"; do
    trmc_name="${trmc_spec%% *}"
    trmc_rest="${trmc_spec#* }"
    trmc_fn="${trmc_rest%% *}"
    trmc_expected="${trmc_rest#* }"
    trmc_wat="$INPUT_WORK/trmc-$trmc_name.wat"
    [ "$(grep -F "(func \$$trmc_fn" "$trmc_wat" | wc -l | tr -d '[:space:]')" -eq 1 ] || {
      echo "FAIL H2B6-WTRMC-P-SHAPE: $trmc_name missing function"
      exit 1
    }
    grep -F 'loop $tmcloop' "$trmc_wat" >/dev/null &&
      grep -F 'br $tmcloop' "$trmc_wat" >/dev/null || {
        echo "FAIL H2B6-WTRMC-P-SHAPE: $trmc_name missing TMC loop markers"
        exit 1
      }
    trmc_named_body "$trmc_fn" "$trmc_wat" > "$INPUT_WORK/trmc-$trmc_name.body"
    [ -s "$INPUT_WORK/trmc-$trmc_name.body" ] &&
      [ "$(grep -F "call \$$trmc_fn" "$INPUT_WORK/trmc-$trmc_name.body" | wc -l | tr -d '[:space:]')" -eq 0 ] &&
      [ "$(grep -F "return_call \$$trmc_fn" "$INPUT_WORK/trmc-$trmc_name.body" | wc -l | tr -d '[:space:]')" -eq 0 ] || {
        echo "FAIL H2B6-WTRMC-P-SHAPE: $trmc_name gained recursive call"
        exit 1
      }
    wasm-tools parse "$trmc_wat" -o "$INPUT_WORK/trmc-$trmc_name.wasm" || {
      echo "FAIL H2B6-WTRMC-P-SHAPE: wasm-tools parse $trmc_name"
      exit 1
    }
    wasm-tools validate --features=all "$INPUT_WORK/trmc-$trmc_name.wasm" || {
      echo "FAIL H2B6-WTRMC-P-SHAPE: wasm-tools validate $trmc_name"
      exit 1
    }
    grep -F "i32.const $trmc_expected" "$INPUT_WORK/trmc-$trmc_name.body" >/dev/null || {
      echo "FAIL H2B6-WTRMC-P-SHAPE: $trmc_name missing named result marker $trmc_expected"
      exit 1
    }
    TRMC_RESULT="$($NODE "$RUNJS" "$INPUT_WORK/trmc-$trmc_name.wasm" 2>"$INPUT_WORK/trmc-$trmc_name.run.err")" || {
      echo "FAIL H2B6-WTRMC-P-SHAPE: execution failed $trmc_name"
      cat "$INPUT_WORK/trmc-$trmc_name.run.err"
      exit 1
    }
    [ ! -s "$INPUT_WORK/trmc-$trmc_name.run.err" ] && [ "$TRMC_RESULT" = "$trmc_expected" ] || {
      echo "FAIL H2B6-WTRMC-P-SHAPE: execution changed $trmc_name"
      exit 1
    }
  done
  [ "$(wc -l < "$INPUT_WORK/trmc-census.events")" -eq 1 ] &&
    grep -F $'val trmcIntentionalGap\tunbound variable '\''missingTrmcCensus' "$INPUT_WORK/trmc-census.events" >/dev/null &&
    grep -F '[in pTrmc]' "$INPUT_WORK/trmc-census.events" >/dev/null || {
      echo "FAIL H2B6-WTRMC-P-SHAPE: census gap attribution"
      exit 1
    }
}
if grep -E '^[[:space:]]*_?(emittedDefaultsWRef|emittedDefaultsSetW|defaultDefsWRef)[[:space:]]*[:=]' "$WASM_SRC" >/dev/null; then
  echo "FAIL H2B4-AUTHORITY-SET: retired default authority remains ambient"
  exit 1
fi
for required in \
  'emittedDefaultNames : Ref (OrdMap Unit)' \
  'defaultDefinitions : Ref (List (List String))' \
  'emittedDefaultNames = Ref omEmpty' \
  'defaultDefinitions = Ref []' \
  'defaultAlreadyEmittedW : WasmEmit -> String -> Bool' \
  'defaultAlreadyEmittedW emit name = omHasKey name emit.emittedDefaultNames.value' \
  'markDefaultEmittedW : WasmEmit -> String -> Unit' \
  'emit.emittedDefaultNames' \
  '(omInsert name () emit.emittedDefaultNames.value)' \
  'addDefaultDefW : WasmEmit -> List String -> Unit' \
  'setRef emit.defaultDefinitions (def::emit.defaultDefinitions.value)' \
  'defaultAlreadyEmittedW (progEmit prog) fname' \
  'markDefaultEmittedW (progEmit prog) fname' \
  'addDefaultDefW' \
  '(emitDefaultDefineW prog fname tag method entry)' \
  'reverseL (progEmit prog).defaultDefinitions.value'; do
  grep -F -- "$required" "$WASM_SRC" >/dev/null || {
    case "$required" in
      *emittedDefaultNames*|*defaultAlreadyEmittedW*|*markDefaultEmittedW*) id=H2B4-DEFAULT-NAMES ;;
      *) id=H2B4-DEFAULT-DEFS ;;
    esac
    echo "FAIL $id: missing routed default-state authority $required"
    exit 1
  }
done
[ "$(grep -F 'flatMap (x => x) (reverseL ' "$WASM_SRC" | grep -F 'defaultDefinitions.value' | wc -l | tr -d '[:space:]')" -eq 2 ] || {
  echo "FAIL H2B4-DEFAULT-DEFS: strict and census default drains must both preserve reverse/flatten order"
  exit 1
}
[ "$(grep -F 'let emit = freshWasmEmit WGapRecord' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 2 ] || {
  echo "FAIL wasm typed string-state ratchet: record and census must each own one fresh WasmEmit"
  exit 1
}
for required_call in \
  'emitLitRef (progEmit prog) (LString s)' \
  'emitLitRef (progEmit prog) l'; do
  [ "$(grep -F -- "$required_call" "$WASM_SRC" | wc -l | tr -d ' ')" -ge 1 ] || {
    echo "FAIL wasm typed string-state ratchet: missing routed call $required_call"
    exit 1
  }
done
[ "$(grep -F 'emitLitRef (progEmit prog) (LString s)' "$WASM_SRC" | wc -l | tr -d '[:space:]')" -eq 3 ] || {
  echo "FAIL wasm typed string-state ratchet: incomplete string-literal routing"
  exit 1
}
for required in \
  'stringCensusProgram : CProgram' \
  'CBind "censusString" [CClause [] (CLit (LString "census-string"))]' \
  'let censusEvents = emitProgramGaps gapStateInput stringCensusProgram'; do
  grep -F -- "$required" "$TYPED_ENTRY" >/dev/null || {
    echo "FAIL wasm typed string-state ratchet: dedicated string census is absent"
    exit 1
  }
done
for required in \
  '"--reemit-default-state"::_' \
  'reemitDefaultState : Unit -> <IO> Unit' \
  'let p1 = emitProgram defaultStateInputP defaultStateProgramP' \
  'let (u, _) = emitProgramRecord defaultStateInputU defaultStateProgramU' \
  'let censusEvents = emitProgramGaps defaultStateInputU defaultStateCensusProgramU' \
  '"DEFAULT_P2"' \
  '(emitProgram defaultStateInputP defaultStateProgramP)' \
  'defaultStateProgramP = defaultStateProgram "PDefault" 17' \
  'defaultStateProgramU = defaultStateProgram "UDefault" 29' \
  'CBind "defaultRequestOne"' \
  'CBind "defaultRequestTwo"' \
  'defaultStateCensusProgramU : CProgram' \
  'CBind "defaultRequestOne" [CClause [PVar "one" defaultStateLoc] (defaultStateCall "UDefault")]' \
  'CBind "defaultRequestTwo" [CClause [PVar "two" defaultStateLoc] (defaultStateCall "UDefault")]' \
  'CBind "defaultCensusGap" [CClause [] (CVar "missingDefaultCensus" AGlobal)]' \
  'CBind "main" [CClause [] (CLit (LInt 0))]' \
  'CImplEntry "synthDefault" 0 (CImplDefault "DefaultFace" [PVar "value" defaultStateLoc] (CLit (LInt 29)))'; do
  grep -F -- "$required" "$TYPED_ENTRY" >/dev/null || {
    echo "FAIL H2B4-DEFAULT-DEFS: default-state harness is missing $required"
    exit 1
  }
done
for required in \
  '"--reemit-lambda-state"::_' \
  'reemitLambdaState : Unit -> <IO> Unit' \
  'let p1 = emitProgram lambdaStateInput (lambdaStateProgram 17)' \
  'let (u, _) = emitProgramRecord lambdaStateInput (lambdaStateProgram 29)' \
  'let censusEvents = emitProgramGaps lambdaStateInput lambdaStateCensusProgram' \
  '"LAMBDA_P2"' \
  '(emitProgram lambdaStateInput (lambdaStateProgram 17))' \
  'lambdaStateProgram : Int -> CProgram' \
  'CBind "lambdaCensus"' \
  'CBind "lambdaIntentionalGap"'; do
  grep -F -- "$required" "$TYPED_ENTRY" >/dev/null || {
    echo "FAIL H2B7-LAMBDA-HARNESS: missing $required"
    exit 1
  }
done

# ── Per-fixture worker (parallel fan-out target); shared state via env ─────────
# Oracle at -O2 (not -O0): TCO fixtures need clang tail-call opt to avoid overflow.
if [ "${1:-}" = "--one" ]; then
  f="$2"; name="$(basename "$f")"
  obin="$WORKDIR/$name.oracle"; wat="$WORKDIR/$name.wat"; wasm="$WORKDIR/$name.wasm"
  st=0; msg=""
  if ! MEDAKA_CLANG_OPT="${WASM_ORACLE_OPT:--O2}" "$MEDAKA" build "$f" -o "$obin" >"$WORKDIR/$name.build.err" 2>&1; then
    msg="$(printf 'FAIL %s (oracle build)\n%s' "$name" "$(cat "$WORKDIR/$name.build.err")")"; st=1
  else
    ref="$("$obin" 2>/dev/null)"
    if ! "$EMITBIN" "$RUNTIME" "$f" > "$wat" 2>"$WORKDIR/$name.emit.err"; then
      msg="$(printf 'FAIL %s (wasm emit)\n%s' "$name" "$(cat "$WORKDIR/$name.emit.err")")"; st=1
    elif ! wasm-tools parse "$wat" -o "$wasm" 2>"$WORKDIR/$name.parse.err"; then
      msg="$(printf 'FAIL %s (wasm-tools parse)\n%s' "$name" "$(cat "$WORKDIR/$name.parse.err")")"; st=1
    elif ! wasm-tools validate --features=all "$wasm" 2>"$WORKDIR/$name.val.err"; then
      msg="$(printf 'FAIL %s (wasm-tools validate)\n%s' "$name" "$(cat "$WORKDIR/$name.val.err")")"; st=1
    else
      got="$("$NODE" "$RUNJS" "$wasm" 2>"$WORKDIR/$name.run.err")"
      if [ "$ref" = "$got" ]; then msg="ok   $name"
      else msg="$(printf 'FAIL %s\n  oracle: %s\n  wasm  : %s\n  (%s)' "$name" "$ref" "$got" "$(cat "$WORKDIR/$name.run.err")")"; st=1; fi
    fi
  fi
  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$msg"
  exit 0
fi

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping W5 gate"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) — skipping W5 gate"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITBIN" ] || { echo "build the wasm typed emitter: sh test/wasm/build_wasm_oracle.sh --typed-only (missing $EMITBIN)"; exit 2; }

# ── Node >= 22 selection (finalized WasmGC encoding — see test/wasm/w1.sh) ─────
NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 22 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
if [ "$major" -lt 22 ]; then
  echo "W5 SKIP  Node >= 22 required for the finalized WasmGC encoding (have $($NODE --version 2>/dev/null))"
  exit 2
fi

INPUT_WORK="$(mktemp -d)"
trap 'rm -rf "$INPUT_WORK"' EXIT

# A0 capture-only apparatus. It fixes P/U/census ordering and executable controls
# before A1–A4 assert any ownership transfer. P's prospective feature routes are
# uncalled, so every normal module remains inert and prints 0.
feature_capture() {
  awk -v begin="$1" -v end="$2" '
    $0 == begin { seenBegin++; capture = 1; next }
    $0 == end { seenEnd++; capture = 0; next }
    capture { print }
    END { if (seenBegin != 1 || seenEnd != 1) exit 1 }
  ' "$3"
}
feature_exact_capture() {
  local begin="$1" end="$2" file="$3" begins ends
  begins="$(grep -Fxc "$begin" "$file" || true)"
  ends="$(grep -Fxc "$end" "$file" || true)"
  [ "$begins" -eq 1 ] && [ "$ends" -eq 1 ] || return 1
  feature_capture "$begin" "$end" "$file"
}

"$EMITBIN" --reemit-feature-state >"$INPUT_WORK/feature.out" 2>"$INPUT_WORK/feature.err"
FEATURE_STATUS=$?
[ "$FEATURE_STATUS" -eq 0 ] && [ ! -s "$INPUT_WORK/feature.err" ] || {
  echo "FAIL A0-FEATURE-CAPTURE: harness status/stderr"
  exit 1
}
FEATURE_MARKERS="$(awk '/^FEATURE_(P1|HASH_INT_ONLY|FLOAT_DIV|RECORD_U|CENSUS_U_GAP|P2)_(BEGIN|END)$/ { print }' "$INPUT_WORK/feature.out")"
FEATURE_EXPECTED_MARKERS="$(printf 'FEATURE_P1_BEGIN\nFEATURE_P1_END\nFEATURE_HASH_INT_ONLY_BEGIN\nFEATURE_HASH_INT_ONLY_END\nFEATURE_FLOAT_DIV_BEGIN\nFEATURE_FLOAT_DIV_END\nFEATURE_RECORD_U_BEGIN\nFEATURE_RECORD_U_END\nFEATURE_CENSUS_U_GAP_BEGIN\nFEATURE_CENSUS_U_GAP_END\nFEATURE_P2_BEGIN\nFEATURE_P2_END')"
[ "$FEATURE_MARKERS" = "$FEATURE_EXPECTED_MARKERS" ] || {
  echo "FAIL A0-FEATURE-CAPTURE: marker cardinality/order"
  exit 1
}
feature_exact_capture FEATURE_P1_BEGIN FEATURE_P1_END "$INPUT_WORK/feature.out" >"$INPUT_WORK/feature-p1.wat" &&
  feature_exact_capture FEATURE_HASH_INT_ONLY_BEGIN FEATURE_HASH_INT_ONLY_END "$INPUT_WORK/feature.out" >"$INPUT_WORK/feature-hash-int-only.wat" &&
  feature_exact_capture FEATURE_FLOAT_DIV_BEGIN FEATURE_FLOAT_DIV_END "$INPUT_WORK/feature.out" >"$INPUT_WORK/feature-float-div.wat" &&
  feature_exact_capture FEATURE_RECORD_U_BEGIN FEATURE_RECORD_U_END "$INPUT_WORK/feature.out" >"$INPUT_WORK/feature-u.wat" &&
  feature_exact_capture FEATURE_CENSUS_U_GAP_BEGIN FEATURE_CENSUS_U_GAP_END "$INPUT_WORK/feature.out" >"$INPUT_WORK/feature-census.events" &&
  feature_exact_capture FEATURE_P2_BEGIN FEATURE_P2_END "$INPUT_WORK/feature.out" >"$INPUT_WORK/feature-p2.wat" || {
    echo "FAIL A0-FEATURE-CAPTURE: malformed capture"
    exit 1
  }
for feature_file in feature-p1.wat feature-hash-int-only.wat feature-float-div.wat feature-u.wat feature-census.events feature-p2.wat; do
  [ -s "$INPUT_WORK/$feature_file" ] || {
    echo "FAIL A0-FEATURE-CAPTURE: empty $feature_file"
    exit 1
  }
done
for feature_p in feature-p1.wat feature-p2.wat; do
  grep -F '(local $__divr0 i64)' "$INPUT_WORK/$feature_p" >/dev/null || {
    echo "FAIL H2B9-DIV-LOCAL: missing ref divisor local in $feature_p"
    exit 1
  }
done
for feature_p in feature-p1.wat feature-p2.wat; do
  grep -F '(local $__rub0 (ref eq))' "$INPUT_WORK/$feature_p" >/dev/null || {
    echo "FAIL H2B9-RECUPDATE-LOCAL: missing record-update local in $feature_p"
    exit 1
  }
done
if grep -F '(local $__divr0 i64)' "$INPUT_WORK/feature-u.wat" >/dev/null; then
  echo "FAIL H2B9-DIV-U-ABSENCE: inert control declared ref divisor local"
  exit 1
fi
if grep -F '(local $__rub0 (ref eq))' "$INPUT_WORK/feature-u.wat" >/dev/null; then
  echo "FAIL H2B9-RECUPDATE-U-ABSENCE: inert control declared record-update local"
  exit 1
fi
for feature_p in feature-p1.wat feature-p2.wat; do
  grep -F '(global $mdk_rng_state' "$INPUT_WORK/$feature_p" >/dev/null &&
    grep -F '(func $mdk_next_u64' "$INPUT_WORK/$feature_p" >/dev/null || {
      echo "FAIL H2B9-RNG-RUNTIME: missing RNG global/runtime in $feature_p"
      exit 1
    }
  grep -F '(func $mdk_hash_mix64' "$INPUT_WORK/$feature_p" >/dev/null &&
    grep -F '(func $mdk_hash_int' "$INPUT_WORK/$feature_p" >/dev/null &&
    grep -F '(func $mdk_hash_string' "$INPUT_WORK/$feature_p" >/dev/null || {
      echo "FAIL H2B9-HASH-RUNTIME: missing base hash runtime in $feature_p"
      exit 1
    }
done
grep -F '(func $mdk_hash_mix64' "$INPUT_WORK/feature-hash-int-only.wat" >/dev/null &&
  grep -F '(func $mdk_hash_int' "$INPUT_WORK/feature-hash-int-only.wat" >/dev/null &&
  ! grep -F '(func $mdk_hash_string' "$INPUT_WORK/feature-hash-int-only.wat" >/dev/null || {
    echo "FAIL H2B9-HASH-NEAREST-MISS: hashInt-only emission changed hash-string conjunction"
    exit 1
  }
if grep -F '$mdk_rng_state' "$INPUT_WORK/feature-u.wat" >/dev/null ||
   grep -F '$mdk_next_u64' "$INPUT_WORK/feature-u.wat" >/dev/null; then
  echo "FAIL H2B9-RNG-U-ABSENCE: inert control emitted RNG global/runtime"
  exit 1
fi
if grep -F '$mdk_hash_mix64' "$INPUT_WORK/feature-u.wat" >/dev/null ||
   grep -F '$mdk_hash_int' "$INPUT_WORK/feature-u.wat" >/dev/null ||
   grep -F '$mdk_hash_string' "$INPUT_WORK/feature-u.wat" >/dev/null; then
  echo "FAIL H2B9-HASH-U-ABSENCE: inert control emitted hash runtime"
  exit 1
fi
grep -F '(local $__divr0 i64)' "$INPUT_WORK/feature-float-div.wat" >/dev/null &&
  grep -F '(func $featureFloatDiv (param $u____wparg0 (ref eq)) (result (ref eq))' "$INPUT_WORK/feature-float-div.wat" >/dev/null &&
  grep -F 'f64.div' "$INPUT_WORK/feature-float-div.wat" >/dev/null || {
  echo "FAIL H2B9-DIV-FLOAT: Float-only division lost ref divisor-local shape"
  exit 1
}
cmp -s "$INPUT_WORK/feature-p1.wat" "$INPUT_WORK/feature-p2.wat" || {
  echo "FAIL A0-FEATURE-CAPTURE: P changed after record U and census"
  exit 1
}
cmp -s "$INPUT_WORK/feature-p1.wat" "$INPUT_WORK/feature-u.wat" && {
  echo "FAIL A0-FEATURE-CAPTURE: P/U positive control did not differ"
  exit 1
}
FEATURE_EVENT="fn featureIntentionalGap	unbound variable 'missingFeatureCensus' (not a local, global value, constructor, or known function) [in featureIntentionalGap]"
[ "$(wc -l < "$INPUT_WORK/feature-census.events")" -eq 1 ] &&
  [ "$(cat "$INPUT_WORK/feature-census.events")" = "$FEATURE_EVENT" ] || {
    echo "FAIL A0-FEATURE-CAPTURE: exact census event"
    exit 1
  }
printf '0\n' >"$INPUT_WORK/feature-expected.out"
for feature_name in p1 hash-int-only float-div u p2; do
  feature_wat="$INPUT_WORK/feature-$feature_name.wat"
  wasm-tools parse "$feature_wat" -o "$INPUT_WORK/feature-$feature_name.wasm" || {
    echo "FAIL A0-FEATURE-CAPTURE: wasm-tools parse $feature_name"
    exit 1
  }
  wasm-tools validate --features=all "$INPUT_WORK/feature-$feature_name.wasm" || {
    echo "FAIL A0-FEATURE-CAPTURE: wasm-tools validate $feature_name"
    exit 1
  }
  "$NODE" "$RUNJS" "$INPUT_WORK/feature-$feature_name.wasm" >"$INPUT_WORK/feature-$feature_name.run.out" 2>"$INPUT_WORK/feature-$feature_name.run.err"
  FEATURE_RUN_STATUS=$?
  [ "$FEATURE_RUN_STATUS" -eq 0 ] && [ ! -s "$INPUT_WORK/feature-$feature_name.run.err" ] &&
    cmp -s "$INPUT_WORK/feature-expected.out" "$INPUT_WORK/feature-$feature_name.run.out" || {
      echo "FAIL A0-FEATURE-CAPTURE: inert execution $feature_name"
      exit 1
    }
done

# Sprint 01 current-binding capture apparatus. The expected events and strict
# diagnostics pin the emission-owned authority and its two write routes.
cbind_capture() {
  awk -v begin="$1" -v end="$2" '
    $0 == begin { seenBegin++; capture = 1; next }
    $0 == end { seenEnd++; capture = 0; next }
    capture { print }
    END { if (seenBegin != 1 || seenEnd != 1) exit 1 }
  ' "$3"
}
cbind_exact_capture() {
  local begin="$1" end="$2" file="$3" begins ends
  begins="$(grep -Fxc "$begin" "$file" || true)"
  ends="$(grep -Fxc "$end" "$file" || true)"
  [ "$begins" -eq 1 ] && [ "$ends" -eq 1 ] || return 1
  cbind_capture "$begin" "$end" "$file"
}
cbind_require_markers() {
  local rule="$1" out="$2" expected="$3" prefix="$4" observed
  observed="$(awk -v prefix="$prefix" '
    $0 == "CBIND_NOWRITER_SETUP_WAT_BEGIN" ||
    $0 == "CBIND_NOWRITER_SETUP_WAT_END" ||
    $0 == "CBIND_NOWRITER_SETUP_OK" ||
    $0 == "CBIND_" prefix "_RECORD_WAT_BEGIN" ||
    $0 == "CBIND_" prefix "_RECORD_WAT_END" ||
    $0 == "CBIND_" prefix "_RECORD_EVENTS_BEGIN" ||
    $0 == "CBIND_" prefix "_RECORD_EVENTS_END" ||
    $0 == "CBIND_" prefix "_CENSUS_EVENTS_BEGIN" ||
    $0 == "CBIND_" prefix "_CENSUS_EVENTS_END" ||
    $0 == "CBIND_" prefix "_STRICT" { print }
  ' "$out")"
  [ "$observed" = "$expected" ] || {
    echo "FAIL $rule: marker cardinality/order"
    printf '  observed markers:\n%s\n' "${observed:-<none>}"
    exit 1
  }
}

"$EMITBIN" --capture-current-binding control >"$INPUT_WORK/cbind-control.out" 2>"$INPUT_WORK/cbind-control.err"
CBIND_CONTROL_STATUS=$?
[ "$CBIND_CONTROL_STATUS" -eq 0 ] && [ ! -s "$INPUT_WORK/cbind-control.err" ] || {
  echo "FAIL CBIND-CONTROL-WAT: control direct status/stderr"
  exit 1
}
cbind_exact_capture CBIND_CONTROL_WAT_BEGIN CBIND_CONTROL_WAT_END "$INPUT_WORK/cbind-control.out" >"$INPUT_WORK/cbind-control.wat" || {
  echo "FAIL CBIND-CONTROL-WAT: exact control markers"
  exit 1
}
[ -s "$INPUT_WORK/cbind-control.wat" ] || { echo "FAIL CBIND-CONTROL-WAT: empty WAT"; exit 1; }
wasm-tools parse "$INPUT_WORK/cbind-control.wat" -o "$INPUT_WORK/cbind-control.wasm" || {
  echo "FAIL CBIND-CONTROL-WAT: wasm-tools parse"; exit 1;
}
wasm-tools validate --features=all "$INPUT_WORK/cbind-control.wasm" || {
  echo "FAIL CBIND-CONTROL-WAT: wasm-tools validate"; exit 1;
}
"$NODE" "$RUNJS" "$INPUT_WORK/cbind-control.wasm" >"$INPUT_WORK/cbind-control.run.out" 2>"$INPUT_WORK/cbind-control.run.err"
CBIND_CONTROL_RUN_STATUS=$?
[ "$CBIND_CONTROL_RUN_STATUS" -eq 0 ] && [ ! -s "$INPUT_WORK/cbind-control.run.err" ] && [ "$(cat "$INPUT_WORK/cbind-control.run.out")" = 0 ] || {
  echo "FAIL CBIND-CONTROL-RUN: inert control did not run as 0"
  exit 1
}

cbind_abort_row() {
  local row="$1" rule="$2" marker="$3" setup="$4" binding="$5" census_prefix="$6" expected prefix upper
  case "$row" in
    top) upper=TOP ;;
    lifted) upper=LIFT ;;
    no-writer) upper=NOWRITER ;;
    post-lift) upper=POSTLIFT ;;
    *) echo "FAIL $rule: unknown capture row"; exit 1 ;;
  esac
  "$EMITBIN" --capture-current-binding "$row" >"$INPUT_WORK/cbind-$row.out" 2>"$INPUT_WORK/cbind-$row.err"
  CBIND_ROW_STATUS=$?
  [ "$CBIND_ROW_STATUS" -eq 1 ] || { echo "FAIL $rule: strict status was $CBIND_ROW_STATUS, expected 1"; exit 1; }
  prefix="${setup:+$setup$'\n'}"
  expected="${prefix}CBIND_${upper}_RECORD_WAT_BEGIN
CBIND_${upper}_RECORD_WAT_END
CBIND_${upper}_RECORD_EVENTS_BEGIN
CBIND_${upper}_RECORD_EVENTS_END
CBIND_${upper}_CENSUS_EVENTS_BEGIN
CBIND_${upper}_CENSUS_EVENTS_END
$marker"
  cbind_require_markers "$rule" "$INPUT_WORK/cbind-$row.out" "$expected" "$upper"
  cbind_exact_capture "CBIND_${upper}_RECORD_EVENTS_BEGIN" "CBIND_${upper}_RECORD_EVENTS_END" "$INPUT_WORK/cbind-$row.out" >"$INPUT_WORK/cbind-$row-record.events" &&
    cbind_exact_capture "CBIND_${upper}_CENSUS_EVENTS_BEGIN" "CBIND_${upper}_CENSUS_EVENTS_END" "$INPUT_WORK/cbind-$row.out" >"$INPUT_WORK/cbind-$row-census.events" || {
      echo "FAIL $rule: malformed event capture"; exit 1;
    }
  cbind_exact_events "$rule" "$INPUT_WORK/cbind-$row-record.events" '?' "$binding"
  cbind_exact_events "$rule" "$INPUT_WORK/cbind-$row-census.events" "$census_prefix" "$binding"
  grep -F 'usage:' "$INPUT_WORK/cbind-$row.out" "$INPUT_WORK/cbind-$row.err" >/dev/null && { echo "FAIL $rule: usage error"; exit 1; }
  grep -Ei 'parse error|type error|type mismatch|setup error' "$INPUT_WORK/cbind-$row.out" "$INPUT_WORK/cbind-$row.err" >/dev/null && {
    echo "FAIL $rule: setup/type failure"
    exit 1
  }
  [ "$(wc -l < "$INPUT_WORK/cbind-$row.err")" -eq 1 ] &&
    [ "$(cat "$INPUT_WORK/cbind-$row.err")" = "runtime error [E-PANIC]: $(cbind_unbound "$binding")" ] || {
    echo "FAIL $rule: strict stderr was not the exact unbound panic"
    exit 1
  }
  [ "$(tail -n 1 "$INPUT_WORK/cbind-$row.out")" = "$marker" ] || {
    echo "FAIL $rule: strict marker was not last"
    exit 1
  }
}

cbind_unbound() {
  printf "unbound variable 'missingCurrentBinding' (not a local, global value, constructor, or known function) [in %s]" "$1"
}
cbind_unsupported() {
  printf 'ref-mode: unsupported Core IR node CMatch (ordered-arm match — needs the decision-tree form) [in %s]' "$1"
}
cbind_exact_events() {
  local rule="$1" file="$2" prefix="$3" binding="$4" expected
  expected="$(printf '%s\t%s\n%s\t%s' "$prefix" "$(cbind_unbound "$binding")" "$prefix" "$(cbind_unsupported "$binding")")"
  [ "$(wc -l < "$file")" -eq 2 ] && [ "$(cat "$file")" = "$expected" ] || {
    echo "FAIL $rule: event lines/order/attribution changed"
    exit 1
  }
}

cbind_abort_row top H2B5-TOP-EXACT CBIND_TOP_STRICT '' P 'fn P'
cbind_abort_row lifted H2B5-LIFT-EXACT CBIND_LIFT_STRICT '' 'lg:P' 'fn outer'
cbind_abort_row no-writer H2B5-NOWRITER-EXACT CBIND_NOWRITER_STRICT $'CBIND_NOWRITER_SETUP_WAT_BEGIN\nCBIND_NOWRITER_SETUP_WAT_END\nCBIND_NOWRITER_SETUP_OK' '?' 'val P'
cbind_abort_row post-lift H2B5-POSTLIFT-EXACT CBIND_POSTLIFT_STRICT '' 'lg:L' 'fn P'

"$EMITBIN" --capture-current-binding malformed >"$INPUT_WORK/cbind-malformed.out" 2>"$INPUT_WORK/cbind-malformed.err"
CBIND_MALFORMED_STATUS=$?
grep -Fx CBIND_MALFORMED_REF_ROUTE "$INPUT_WORK/cbind-malformed.out" >/dev/null || {
  echo "FAIL CBIND-MALFORMED-NONREADER: missing ref-route classification"; exit 1;
}
[ "$(grep -Fxc CBIND_MALFORMED_REF_ROUTE "$INPUT_WORK/cbind-malformed.out" || true)" -eq 1 ] || {
  echo "FAIL CBIND-MALFORMED-NONREADER: route marker cardinality"; exit 1;
}
grep -F 'only PVar/PWild parameters' "$INPUT_WORK/cbind-malformed.err" >/dev/null && {
  echo "FAIL CBIND-MALFORMED-NONREADER: malformed route reached patName"; exit 1;
}
[ "$CBIND_MALFORMED_STATUS" -eq 0 ] && [ ! -s "$INPUT_WORK/cbind-malformed.err" ] || {
  echo "FAIL CBIND-MALFORMED-NONREADER: ref-route did not emit cleanly"
  exit 1
}
cbind_exact_capture CBIND_MALFORMED_WAT_BEGIN CBIND_MALFORMED_WAT_END "$INPUT_WORK/cbind-malformed.out" >"$INPUT_WORK/cbind-malformed.wat" || {
  echo "FAIL CBIND-MALFORMED-NONREADER: malformed WAT markers"; exit 1;
}
[ -s "$INPUT_WORK/cbind-malformed.wat" ] || { echo "FAIL CBIND-MALFORMED-NONREADER: empty malformed WAT"; exit 1; }
wasm-tools parse "$INPUT_WORK/cbind-malformed.wat" -o "$INPUT_WORK/cbind-malformed.wasm" || {
  echo "FAIL CBIND-MALFORMED-NONREADER: wasm-tools parse"; exit 1;
}
wasm-tools validate --features=all "$INPUT_WORK/cbind-malformed.wasm" || {
  echo "FAIL CBIND-MALFORMED-NONREADER: wasm-tools validate"; exit 1;
}

# X-W.H1: one process emits one lowered P program with P's complete input, each
# U-derived field in isolation, then P's input again. This distinguishes explicit
# inputs from CProgram changes and proves the final P is not contaminated.
cat > "$INPUT_WORK/p.mdk" <<'EOF'
interface Score a where
  score : a -> Int

data P = P

impl Score P where
  score = x => 7

data R = R { i : Int, f : Float }

negR : R -> Float
negR r = -r.f

dbl : Float -> Float
dbl x = x + x

data Cell = CInt Int | CFloat Float

cellNumF : Cell -> Float
cellNumF c = match c
  CInt n => intToFloat n
  CFloat f => f

sumCells : List Cell -> Float
sumCells cells = match cells
  [] => 0.0
  c :: rest => cellNumF c + sumCells rest

asFloat : Int -> Float
asFloat n = intToFloat n

data Box = Box Float

negBox : Box -> Float
negBox b = match b
  Box f => -f

main = asFloat 1
EOF
cat > "$INPUT_WORK/u.mdk" <<'EOF'
interface Score a where
  score : a -> Int -> Int

data R = R { f : Float, i : Int }

negR : R -> Int
negR _ = 0

dbl : Int -> Int
dbl x = x + x

cellNumF : Cell -> Int
cellNumF _ = 0

sumCells : List Cell -> Int
sumCells _ = 0

asFloat : Int -> Int
asFloat n = n

data Box = Box Int
EOF
REEMIT_OUT="$($EMITBIN --reemit-input "$RUNTIME" "$INPUT_WORK/p.mdk" "$INPUT_WORK/u.mdk")" || {
  echo "FAIL wasm typed same-process input harness"
  exit 1
}
REEMIT_EXPECTED="$(printf 'P_EQ_PLAST\nP_NE_METHOD\nP_NE_SIG\nP_NE_CTOR\nP_NE_MAIN\nP_NE_RECORD')"
[ "$REEMIT_OUT" = "$REEMIT_EXPECTED" ] || {
  echo "FAIL wasm typed input isolation: an explicit field did not discriminate: $REEMIT_OUT"
  exit 1
}

# X-W.H2a: sequence normal P -> normal U -> gap U -> normal P in one process.
# Compare complete captures in the shell so a marker-only driver cannot satisfy this.
STATE_OUT="$($EMITBIN --reemit-state "$RUNTIME")" || {
  echo "FAIL wasm typed same-process state harness"
  exit 1
}
STATE_MARKERS="$(printf '%s\n' "$STATE_OUT" | awk '/^REEMIT_(P1_BEGIN|P1_END|U_BEGIN|U_END|P2_BEGIN|P2_END)$/ { print }')"
STATE_EXPECTED_MARKERS="$(printf 'REEMIT_P1_BEGIN\nREEMIT_P1_END\nREEMIT_U_BEGIN\nREEMIT_U_END\nREEMIT_P2_BEGIN\nREEMIT_P2_END')"
[ "$STATE_MARKERS" = "$STATE_EXPECTED_MARKERS" ] || {
  echo "FAIL wasm typed state isolation: expected exactly six ordered markers"
  printf '  observed markers:\n%s\n' "${STATE_MARKERS:-<none>}"
  exit 1
}
state_capture() {
  awk -v begin="$1" -v end="$2" '
    $0 == begin { capture = 1; next }
    $0 == end { exit }
    capture { print }
  ' <<<"$STATE_OUT"
}
state_capture REEMIT_P1_BEGIN REEMIT_P1_END > "$INPUT_WORK/p1.wat"
state_capture REEMIT_U_BEGIN REEMIT_U_END > "$INPUT_WORK/u.wat"
state_capture REEMIT_P2_BEGIN REEMIT_P2_END > "$INPUT_WORK/p2.wat"
[ -s "$INPUT_WORK/p1.wat" ] && [ -s "$INPUT_WORK/u.wat" ] && [ -s "$INPUT_WORK/p2.wat" ] || {
  echo "FAIL wasm typed state isolation: empty capture"
  exit 1
}
for state_wat in p1 u p2; do
  wasm-tools parse "$INPUT_WORK/$state_wat.wat" -o "$INPUT_WORK/$state_wat.wasm" || {
    echo "FAIL wasm typed state isolation: wasm-tools parse $state_wat"
    exit 1
  }
  wasm-tools validate --features=all "$INPUT_WORK/$state_wat.wasm" || {
    echo "FAIL wasm typed state isolation: wasm-tools validate $state_wat"
    exit 1
  }
done
cmp -s "$INPUT_WORK/p1.wat" "$INPUT_WORK/p2.wat" || {
  echo "FAIL wasm typed state isolation: P changed after U and gap U"
  exit 1
}
cmp -s "$INPUT_WORK/p1.wat" "$INPUT_WORK/u.wat" && {
  echo "FAIL wasm typed state isolation: P/U positive control did not differ"
  exit 1
}

# X-W.H2b.1: record and census emissions must not leak mode, events, or
# attribution into a following strict emission in the same process.
GAP_OUT="$($EMITBIN --reemit-gap-state)" || {
  echo "FAIL wasm typed same-process gap lifecycle harness"
  exit 1
}
GAP_MARKERS="$(printf '%s\n' "$GAP_OUT" | awk '/^GAP_(P1|RECORD_WAT|RECORD_EVENTS|CENSUS_EVENTS|P2)_(BEGIN|END)$/ { print }')"
GAP_EXPECTED_MARKERS="$(printf 'GAP_P1_BEGIN\nGAP_P1_END\nGAP_RECORD_WAT_BEGIN\nGAP_RECORD_WAT_END\nGAP_RECORD_EVENTS_BEGIN\nGAP_RECORD_EVENTS_END\nGAP_CENSUS_EVENTS_BEGIN\nGAP_CENSUS_EVENTS_END\nGAP_P2_BEGIN\nGAP_P2_END')"
[ "$GAP_MARKERS" = "$GAP_EXPECTED_MARKERS" ] || {
  echo "FAIL wasm typed gap lifecycle: expected exactly ten ordered markers"
  exit 1
}
gap_capture() {
  awk -v begin="$1" -v end="$2" '
    $0 == begin { capture = 1; next }
    $0 == end { exit }
    capture { print }
  ' <<<"$GAP_OUT"
}
gap_capture GAP_P1_BEGIN GAP_P1_END > "$INPUT_WORK/gap-p1.wat"
gap_capture GAP_RECORD_WAT_BEGIN GAP_RECORD_WAT_END > "$INPUT_WORK/gap-record.wat"
gap_capture GAP_RECORD_EVENTS_BEGIN GAP_RECORD_EVENTS_END > "$INPUT_WORK/gap-record.events"
gap_capture GAP_CENSUS_EVENTS_BEGIN GAP_CENSUS_EVENTS_END > "$INPUT_WORK/gap-census.events"
gap_capture GAP_P2_BEGIN GAP_P2_END > "$INPUT_WORK/gap-p2.wat"
for gap_capture_file in gap-p1.wat gap-record.wat gap-record.events gap-census.events gap-p2.wat; do
  [ -s "$INPUT_WORK/$gap_capture_file" ] || {
    echo "FAIL wasm typed gap lifecycle: empty $gap_capture_file"
    exit 1
  }
done
cmp -s "$INPUT_WORK/gap-p1.wat" "$INPUT_WORK/gap-p2.wat" || {
  echo "FAIL wasm typed gap lifecycle: strict P changed after record and census emissions"
  exit 1
}
for gap_p in gap-p1 gap-p2; do
  wasm-tools parse "$INPUT_WORK/$gap_p.wat" -o "$INPUT_WORK/$gap_p.wasm" || {
    echo "FAIL wasm typed gap lifecycle: wasm-tools parse $gap_p"
    exit 1
  }
  wasm-tools validate --features=all "$INPUT_WORK/$gap_p.wasm" || {
    echo "FAIL wasm typed gap lifecycle: wasm-tools validate $gap_p"
    exit 1
  }
done
[ "$(wc -l < "$INPUT_WORK/gap-record.events")" -eq 2 ] &&
  sed -n '1p' "$INPUT_WORK/gap-record.events" | grep -F $'?\tunbound variable '\''missingGapB' >/dev/null &&
  sed -n '2p' "$INPUT_WORK/gap-record.events" | grep -F $'?\tunbound variable '\''missingGapA' >/dev/null || {
    echo "FAIL wasm typed gap lifecycle: record events lost order or freshness"
    exit 1
  }
[ "$(wc -l < "$INPUT_WORK/gap-census.events")" -eq 2 ] &&
  sed -n '1p' "$INPUT_WORK/gap-census.events" | grep -F $'val gapA\tunbound variable '\''missingGapA' >/dev/null &&
  sed -n '2p' "$INPUT_WORK/gap-census.events" | grep -F $'val gapB\tunbound variable '\''missingGapB' >/dev/null || {
    echo "FAIL wasm typed gap lifecycle: census events lost binding attribution or order"
    exit 1
  }
if "$EMITBIN" --reemit-gap-strict >"$INPUT_WORK/strict-gap.out" 2>"$INPUT_WORK/strict-gap.err"; then
  echo "FAIL wasm typed gap lifecycle: same-process strict gap unexpectedly recorded"
  exit 1
fi
grep -Fx "GAP_STRICT_AFTER_RECORD_CENSUS" "$INPUT_WORK/strict-gap.out" >/dev/null || {
  echo "FAIL wasm typed gap lifecycle: record/census setup did not precede strict gap"
  exit 1
}
grep -F "unbound variable 'missingGapB'" "$INPUT_WORK/strict-gap.err" >/dev/null || {
  echo "FAIL wasm typed gap lifecycle: same-process strict gap lost its loud diagnostic"
  exit 1
}

state_family_fail() {
  echo "FAIL wasm typed state isolation [$1]: $2"
  exit 1
}
require_wat() {
  grep -F -- "$3" "$2" >/dev/null || state_family_fail "$1" "missing $3"
}
forbid_wat() {
  grep -F -- "$3" "$2" >/dev/null && state_family_fail "$1" "unexpected $3"
}
require_fn_arity() {
  awk -v name="$2" -v want="$3" '
    $0 ~ "^  \\(func \\$" name {
      n = gsub(/\(param /, "&")
      if (n == want) found = 1
    }
    END { exit !found }
  ' "$4" || state_family_fail "$1" "expected $2 arity $3"
}
require_ctor_fields() {
  awk -v want="$2" '
    /\(type \$C_SharedCtor / {
      n = gsub(/\(field /, "&")
      if (n == want) found = 1
    }
    END { exit !found }
  ' "$3" || state_family_fail "$1" "expected SharedCtor field count $2"
}
require_ctor_ordinal() {
  awk -v want="$2" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "i32.const 0" || line == "i32.const 1") last = line
      if (line == "struct.new $C_SharedCtor") {
        found = 1
        if (last != "i32.const " want) mismatch = 1
      }
    }
    END { exit !(found && !mismatch) }
  ' "$3" || state_family_fail "$1" "expected every SharedCtor construction to use ordinal $2"
}

P1_WAT="$INPUT_WORK/p1.wat"
U_WAT="$INPUT_WORK/u.wat"
require_wat fn-names "$P1_WAT" 'call $pOnlyFn'
forbid_wat fn-names "$P1_WAT" 'call $uOnlyFn'
require_wat fn-names "$U_WAT" 'call $uOnlyFn'
forbid_wat fn-names "$U_WAT" 'call $pOnlyFn'
require_wat value-names "$P1_WAT" 'global.get $pOnlyValue'
forbid_wat value-names "$P1_WAT" 'global.get $uOnlyValue'
require_wat value-names "$U_WAT" 'global.get $uOnlyValue'
forbid_wat value-names "$U_WAT" 'global.get $pOnlyValue'
require_fn_arity fn-arity sharedArity 1 "$P1_WAT"
require_wat fn-arity "$P1_WAT" 'call $sharedArity'
require_fn_arity fn-arity sharedArity 2 "$U_WAT"
require_wat fn-arity "$U_WAT" 'call $sharedArity'
require_wat impl-buckets "$P1_WAT" '(func $mdk_impl_PSubject_mark'
require_wat impl-buckets "$P1_WAT" 'call $mdk_impl_PSubject_mark'
require_wat impl-buckets "$U_WAT" '(func $mdk_impl_USubject_mark'
require_wat impl-buckets "$U_WAT" 'call $mdk_impl_USubject_mark'
require_wat lazy-globals "$P1_WAT" '(global $gs_pLazy'
require_wat lazy-globals "$P1_WAT" '(func $force_pLazy'
require_wat lazy-globals "$P1_WAT" 'call $force_pLazy'
require_wat lazy-globals "$U_WAT" '(global $gs_uLazy'
require_wat lazy-globals "$U_WAT" '(func $force_uLazy'
require_wat lazy-globals "$U_WAT" 'call $force_uLazy'
require_wat record-fallback-field-slots "$P1_WAT" 'struct.get $C_SharedRecord 2'
require_wat record-fallback-field-slots "$U_WAT" 'struct.get $C_SharedRecord 1'
require_wat function-value-wrappers "$P1_WAT" '(func $mdk_w_sharedArity'
require_wat function-value-wrappers "$P1_WAT" 'ref.func $mdk_w_sharedArity'
require_wat function-value-wrappers "$U_WAT" '(func $mdk_w_sharedArity'
require_wat function-value-wrappers "$U_WAT" 'ref.func $mdk_w_sharedArity'
require_wat function-value-wrappers "$P1_WAT" '(func $mdk_w_sharedValueFn'
require_wat function-value-wrappers "$P1_WAT" 'ref.func $mdk_w_sharedValueFn'
forbid_wat function-value-wrappers "$U_WAT" '(func $mdk_w_sharedValueFn'
require_wat function-value-wrappers "$U_WAT" 'call $sharedValueFn'
require_ctor_fields ctor-arity 2 "$P1_WAT"
require_wat ctor-arity "$P1_WAT" 'struct.new $C_SharedCtor'
require_ctor_fields ctor-arity 3 "$U_WAT"
require_wat ctor-arity "$U_WAT" 'struct.new $C_SharedCtor'
require_wat ctor-owner-type "$P1_WAT" '(type $C_SharedCtor (sub $T_PSubject'
require_wat ctor-owner-type "$P1_WAT" 'ref.cast (ref $T_PSubject)'
require_wat ctor-owner-type "$U_WAT" '(type $C_SharedCtor (sub $T_USubject'
require_wat ctor-owner-type "$U_WAT" 'ref.cast (ref $T_USubject)'
require_ctor_ordinal ctor-ordinal 1 "$P1_WAT"
require_ctor_ordinal ctor-ordinal 0 "$U_WAT"
require_wat type-to-ctors "$P1_WAT" '(type $T_PSubject (sub (struct (field i32)))'
forbid_wat type-to-ctors "$P1_WAT" '(type $T_USubject (sub (struct (field i32)))'
require_wat type-to-ctors "$P1_WAT" 'ref.cast (ref $T_PSubject)'
require_wat type-to-ctors "$U_WAT" '(type $T_USubject (sub (struct (field i32)))'
forbid_wat type-to-ctors "$U_WAT" '(type $T_PSubject (sub (struct (field i32)))'
require_wat type-to-ctors "$U_WAT" 'ref.cast (ref $T_USubject)'

run_impl_self_check
run_trmc_state_check

for required in \
  '"--reemit-trap-state"::_' \
  '"--emit-trap-state"::_' \
  'reemitTrapState : Unit -> <IO> Unit' \
  'let p1 = emitProgram trapStateInput trapStateProgram' \
  'let (u, _) = emitProgramRecord trapStateInput trapStateControlProgram' \
  'let censusEvents = emitProgramGaps trapStateInput trapStateCensusProgram' \
  '"TRAP_P2"' \
  'trapStateAbortProgram : CProgram' \
  'CBind "trapIntentionalGap"'; do
  grep -F -- "$required" "$TYPED_ENTRY" >/dev/null || {
    echo "FAIL H2B8-TRAP-HARNESS: missing $required"
    exit 1
  }
done
TRAP_OUT="$($EMITBIN --reemit-trap-state 2>"$INPUT_WORK/trap.emit.err")" || {
  echo "FAIL H2B8-TRAP-LIFECYCLE: trap state harness"
  cat "$INPUT_WORK/trap.emit.err"
  exit 1
}
[ ! -s "$INPUT_WORK/trap.emit.err" ] || {
  echo "FAIL H2B8-TRAP-LIFECYCLE: harness wrote stderr"
  cat "$INPUT_WORK/trap.emit.err"
  exit 1
}
TRAP_MARKERS="$(printf '%s\n' "$TRAP_OUT" | awk '/^TRAP_(P1|RECORD_U|CENSUS_U_GAP|P2)_(BEGIN|END)$/ { print }')"
TRAP_EXPECTED_MARKERS="$(printf 'TRAP_P1_BEGIN\nTRAP_P1_END\nTRAP_RECORD_U_BEGIN\nTRAP_RECORD_U_END\nTRAP_CENSUS_U_GAP_BEGIN\nTRAP_CENSUS_U_GAP_END\nTRAP_P2_BEGIN\nTRAP_P2_END')"
[ "$TRAP_MARKERS" = "$TRAP_EXPECTED_MARKERS" ] || {
  echo "FAIL H2B8-TRAP-LIFECYCLE: ordered capture markers"
  exit 1
}
trap_capture() {
  awk -v begin="$1" -v end="$2" '
    $0 == begin { capture = 1; next }
    $0 == end { exit }
    capture { print }
  ' <<<"$TRAP_OUT"
}
trap_capture TRAP_P1_BEGIN TRAP_P1_END > "$INPUT_WORK/trap-p1.wat"
trap_capture TRAP_RECORD_U_BEGIN TRAP_RECORD_U_END > "$INPUT_WORK/trap-u.wat"
trap_capture TRAP_CENSUS_U_GAP_BEGIN TRAP_CENSUS_U_GAP_END > "$INPUT_WORK/trap-census.events"
trap_capture TRAP_P2_BEGIN TRAP_P2_END > "$INPUT_WORK/trap-p2.wat"
for trap_file in trap-p1.wat trap-u.wat trap-census.events trap-p2.wat; do
  [ -s "$INPUT_WORK/$trap_file" ] || {
    echo "FAIL H2B8-TRAP-LIFECYCLE: empty $trap_file"
    exit 1
  }
done
cmp -s "$INPUT_WORK/trap-p1.wat" "$INPUT_WORK/trap-p2.wat" || {
  echo "FAIL H2B8-TRAP-LIFECYCLE: P changed after record U and census"
  exit 1
}
for trap_spec in 'p1 17 present' 'u 29 absent' 'p2 17 present'; do
  trap_name="${trap_spec%% *}"
  trap_rest="${trap_spec#* }"
  trap_result="${trap_rest%% *}"
  trap_import="${trap_rest#* }"
  trap_wat="$INPUT_WORK/trap-$trap_name.wat"
  trap_import_count="$(grep -F '(import "env" "mdk_write_err_byte"' "$trap_wat" | wc -l | tr -d '[:space:]')"
  if [ "$trap_import" = present ]; then [ "$trap_import_count" -eq 1 ]; else [ "$trap_import_count" -eq 0 ]; fi || {
    echo "FAIL H2B8-TRAP-IMPORT: $trap_name import presence/order changed"
    exit 1
  }
  wasm-tools parse "$trap_wat" -o "$INPUT_WORK/trap-$trap_name.wasm" || {
    echo "FAIL H2B8-TRAP-LIFECYCLE: wasm-tools parse $trap_name"
    exit 1
  }
  wasm-tools validate --features=all "$INPUT_WORK/trap-$trap_name.wasm" || {
    echo "FAIL H2B8-TRAP-LIFECYCLE: wasm-tools validate $trap_name"
    exit 1
  }
  TRAP_RESULT="$($NODE "$RUNJS" "$INPUT_WORK/trap-$trap_name.wasm" 2>"$INPUT_WORK/trap-$trap_name.run.err")" || {
    echo "FAIL H2B8-TRAP-LIFECYCLE: inert execution failed $trap_name"
    cat "$INPUT_WORK/trap-$trap_name.run.err"
    exit 1
  }
  [ ! -s "$INPUT_WORK/trap-$trap_name.run.err" ] && [ "$TRAP_RESULT" = "$trap_result" ] || {
    echo "FAIL H2B8-TRAP-LIFECYCLE: inert output/stderr changed $trap_name"
    exit 1
  }
done
[ "$(wc -l < "$INPUT_WORK/trap-census.events")" -eq 1 ] &&
  grep -F $'val trapIntentionalGap\tunbound variable '\''missingTrapCensus' "$INPUT_WORK/trap-census.events" >/dev/null || {
  echo "FAIL H2B8-TRAP-LIFECYCLE: census event attribution"
  exit 1
}
"$EMITBIN" --emit-trap-state > "$INPUT_WORK/trap-abort.wat" 2>"$INPUT_WORK/trap-abort.emit.err" || {
  echo "FAIL H2B8-TRAP-ABORT: emitter failed"
  cat "$INPUT_WORK/trap-abort.emit.err"
  exit 1
}
[ ! -s "$INPUT_WORK/trap-abort.emit.err" ] &&
  wasm-tools parse "$INPUT_WORK/trap-abort.wat" -o "$INPUT_WORK/trap-abort.wasm" &&
  wasm-tools validate --features=all "$INPUT_WORK/trap-abort.wasm" || {
  echo "FAIL H2B8-TRAP-ABORT: emit/parse/validate"
  exit 1
}
if TRAP_ABORT_OUT="$($NODE "$RUNJS" "$INPUT_WORK/trap-abort.wasm" 2>"$INPUT_WORK/trap-abort.run.err")"; then
  echo "FAIL H2B8-TRAP-ABORT: trap route exited zero"
  exit 1
fi
[ -z "$TRAP_ABORT_OUT" ] &&
  [ "$(cat "$INPUT_WORK/trap-abort.run.err")" = 'runtime error [E-DIV-ZERO]: division by zero' ] || {
  echo "FAIL H2B8-TRAP-ABORT: exact runtime diagnostic changed"
  exit 1
}

# Census above is ownership-only: it records a gap while its trap-bearing binding
# structurally exercises fresh authority. This P/U/P control observes ref-mode data:
# its ADT table forces the distinct emitRefProgram late-import reader. A future renamed
# ambient-authority mutant must first fail H2B8-AUTHORITY-SET; no artifact mutation here.
REF_TRAP_OUT="$($EMITBIN --reemit-ref-trap-state 2>"$INPUT_WORK/ref-trap.emit.err")" || {
  echo "FAIL H2B8-REF-TRAP-LIFECYCLE: ref trap harness"
  cat "$INPUT_WORK/ref-trap.emit.err"
  exit 1
}
[ ! -s "$INPUT_WORK/ref-trap.emit.err" ] || {
  echo "FAIL H2B8-REF-TRAP-LIFECYCLE: harness wrote stderr"
  cat "$INPUT_WORK/ref-trap.emit.err"
  exit 1
}
REF_TRAP_MARKERS="$(printf '%s\n' "$REF_TRAP_OUT" | awk '/^REF_TRAP_(P1|U|P2)_(BEGIN|END)$/ { print }')"
REF_TRAP_EXPECTED_MARKERS="$(printf 'REF_TRAP_P1_BEGIN\nREF_TRAP_P1_END\nREF_TRAP_U_BEGIN\nREF_TRAP_U_END\nREF_TRAP_P2_BEGIN\nREF_TRAP_P2_END')"
[ "$REF_TRAP_MARKERS" = "$REF_TRAP_EXPECTED_MARKERS" ] || {
  echo "FAIL H2B8-REF-TRAP-LIFECYCLE: ordered capture markers"
  exit 1
}
ref_trap_capture() {
  awk -v begin="$1" -v end="$2" '
    $0 == begin { capture = 1; next }
    $0 == end { exit }
    capture { print }
  ' <<<"$REF_TRAP_OUT"
}
ref_trap_capture REF_TRAP_P1_BEGIN REF_TRAP_P1_END > "$INPUT_WORK/ref-trap-p1.wat"
ref_trap_capture REF_TRAP_U_BEGIN REF_TRAP_U_END > "$INPUT_WORK/ref-trap-u.wat"
ref_trap_capture REF_TRAP_P2_BEGIN REF_TRAP_P2_END > "$INPUT_WORK/ref-trap-p2.wat"
cmp -s "$INPUT_WORK/ref-trap-p1.wat" "$INPUT_WORK/ref-trap-p2.wat" || {
  echo "FAIL H2B8-REF-TRAP-LIFECYCLE: ref P changed after U"
  exit 1
}
for ref_trap_spec in 'p1 17 present' 'u 29 absent' 'p2 17 present'; do
  ref_trap_name="${ref_trap_spec%% *}"
  ref_trap_rest="${ref_trap_spec#* }"
  ref_trap_result="${ref_trap_rest%% *}"
  ref_trap_import="${ref_trap_rest#* }"
  ref_trap_wat="$INPUT_WORK/ref-trap-$ref_trap_name.wat"
  grep -F '(type $T_TrapToken' "$ref_trap_wat" >/dev/null || {
    echo "FAIL H2B8-REF-TRAP-MODE: $ref_trap_name did not force ref mode"
    exit 1
  }
  ref_trap_import_count="$(grep -F '(import "env" "mdk_write_err_byte"' "$ref_trap_wat" | wc -l | tr -d '[:space:]')"
  if [ "$ref_trap_import" = present ]; then [ "$ref_trap_import_count" -eq 1 ]; else [ "$ref_trap_import_count" -eq 0 ]; fi || {
    echo "FAIL H2B8-REF-TRAP-IMPORT: $ref_trap_name ref late-import predicate changed"
    exit 1
  }
  wasm-tools parse "$ref_trap_wat" -o "$INPUT_WORK/ref-trap-$ref_trap_name.wasm" &&
    wasm-tools validate --features=all "$INPUT_WORK/ref-trap-$ref_trap_name.wasm" || {
    echo "FAIL H2B8-REF-TRAP-LIFECYCLE: parse/validate $ref_trap_name"
    exit 1
  }
  REF_TRAP_RESULT="$($NODE "$RUNJS" "$INPUT_WORK/ref-trap-$ref_trap_name.wasm" 2>"$INPUT_WORK/ref-trap-$ref_trap_name.run.err")" || {
    echo "FAIL H2B8-REF-TRAP-LIFECYCLE: inert execution failed $ref_trap_name"
    exit 1
  }
  [ ! -s "$INPUT_WORK/ref-trap-$ref_trap_name.run.err" ] && [ "$REF_TRAP_RESULT" = "$ref_trap_result" ] || {
    echo "FAIL H2B8-REF-TRAP-LIFECYCLE: output/stderr changed $ref_trap_name"
    exit 1
  }
done
"$EMITBIN" --emit-ref-trap-state > "$INPUT_WORK/ref-trap-abort.wat" 2>"$INPUT_WORK/ref-trap-abort.emit.err" &&
  [ ! -s "$INPUT_WORK/ref-trap-abort.emit.err" ] &&
  wasm-tools parse "$INPUT_WORK/ref-trap-abort.wat" -o "$INPUT_WORK/ref-trap-abort.wasm" &&
  wasm-tools validate --features=all "$INPUT_WORK/ref-trap-abort.wasm" || {
  echo "FAIL H2B8-REF-TRAP-ABORT: emit/parse/validate"
  exit 1
}
if REF_TRAP_ABORT_OUT="$($NODE "$RUNJS" "$INPUT_WORK/ref-trap-abort.wasm" 2>"$INPUT_WORK/ref-trap-abort.run.err")"; then
  echo "FAIL H2B8-REF-TRAP-ABORT: ref trap exited zero"
  exit 1
fi
[ -z "$REF_TRAP_ABORT_OUT" ] &&
  [ "$(cat "$INPUT_WORK/ref-trap-abort.run.err")" = 'runtime error [E-DIV-ZERO]: division by zero' ] || {
  echo "FAIL H2B8-REF-TRAP-ABORT: exact ref runtime diagnostic changed"
  exit 1
}

LAMBDA_OUT="$($EMITBIN --reemit-lambda-state 2>"$INPUT_WORK/lambda.emit.err")" || {
  echo "FAIL H2B7-LAMBDA-LIFECYCLE: lambda state harness"
  cat "$INPUT_WORK/lambda.emit.err"
  exit 1
}
[ ! -s "$INPUT_WORK/lambda.emit.err" ] || {
  echo "FAIL H2B7-LAMBDA-LIFECYCLE: harness wrote stderr"
  cat "$INPUT_WORK/lambda.emit.err"
  exit 1
}
LAMBDA_MARKERS="$(printf '%s\n' "$LAMBDA_OUT" | awk '/^LAMBDA_(P1|RECORD_U|CENSUS_U_GAP|P2)_(BEGIN|END)$/ { print }')"
LAMBDA_EXPECTED_MARKERS="$(printf 'LAMBDA_P1_BEGIN\nLAMBDA_P1_END\nLAMBDA_RECORD_U_BEGIN\nLAMBDA_RECORD_U_END\nLAMBDA_CENSUS_U_GAP_BEGIN\nLAMBDA_CENSUS_U_GAP_END\nLAMBDA_P2_BEGIN\nLAMBDA_P2_END')"
[ "$LAMBDA_MARKERS" = "$LAMBDA_EXPECTED_MARKERS" ] || {
  echo "FAIL H2B7-LAMBDA-LIFECYCLE: ordered capture markers"
  exit 1
}
lambda_capture() {
  awk -v begin="$1" -v end="$2" '
    $0 == begin { capture = 1; next }
    $0 == end { exit }
    capture { print }
  ' <<<"$LAMBDA_OUT"
}
lambda_capture LAMBDA_P1_BEGIN LAMBDA_P1_END > "$INPUT_WORK/lambda-p1.wat"
lambda_capture LAMBDA_RECORD_U_BEGIN LAMBDA_RECORD_U_END > "$INPUT_WORK/lambda-u.wat"
lambda_capture LAMBDA_CENSUS_U_GAP_BEGIN LAMBDA_CENSUS_U_GAP_END > "$INPUT_WORK/lambda-census.events"
lambda_capture LAMBDA_P2_BEGIN LAMBDA_P2_END > "$INPUT_WORK/lambda-p2.wat"
for lambda_file in lambda-p1.wat lambda-u.wat lambda-census.events lambda-p2.wat; do
  [ -s "$INPUT_WORK/$lambda_file" ] || {
    echo "FAIL H2B7-LAMBDA-LIFECYCLE: empty $lambda_file"
    exit 1
  }
done
cmp -s "$INPUT_WORK/lambda-p1.wat" "$INPUT_WORK/lambda-p2.wat" || {
  echo "FAIL H2B7-LAMBDA-LIFECYCLE: P changed after record U and census"
  exit 1
}
cmp -s "$INPUT_WORK/lambda-p1.wat" "$INPUT_WORK/lambda-u.wat" && {
  echo "FAIL H2B7-LAMBDA-LIFECYCLE: P/U positive control did not differ"
  exit 1
}
for lambda_spec in 'p1 17 1' 'u 29 2' 'p2 17 1'; do
  lambda_name="${lambda_spec%% *}"
  lambda_rest="${lambda_spec#* }"
  lambda_result="${lambda_rest%% *}"
  lambda_count="${lambda_rest#* }"
  lambda_wat="$INPUT_WORK/lambda-$lambda_name.wat"
  [ "$(grep -E '^  \(func \$mdk_lam[0-9]+' "$lambda_wat" | wc -l | tr -d '[:space:]')" -eq "$lambda_count" ] &&
    [ "$(grep -E '^  \(elem declare func .*\$mdk_lam0' "$lambda_wat" | wc -l | tr -d '[:space:]')" -eq 1 ] || {
      echo "FAIL H2B7-LAMBDA-LIFECYCLE: $lambda_name lambda definition/ref declaration changed"
      exit 1
    }
  wasm-tools parse "$lambda_wat" -o "$INPUT_WORK/lambda-$lambda_name.wasm" || {
    echo "FAIL H2B7-LAMBDA-LIFECYCLE: wasm-tools parse $lambda_name"
    exit 1
  }
  wasm-tools validate --features=all "$INPUT_WORK/lambda-$lambda_name.wasm" || {
    echo "FAIL H2B7-LAMBDA-LIFECYCLE: wasm-tools validate $lambda_name"
    exit 1
  }
  LAMBDA_RESULT="$($NODE "$RUNJS" "$INPUT_WORK/lambda-$lambda_name.wasm" 2>"$INPUT_WORK/lambda-$lambda_name.run.err")" || {
    echo "FAIL H2B7-LAMBDA-LIFECYCLE: execution failed $lambda_name"
    cat "$INPUT_WORK/lambda-$lambda_name.run.err"
    exit 1
  }
  [ ! -s "$INPUT_WORK/lambda-$lambda_name.run.err" ] && [ "$LAMBDA_RESULT" = "$lambda_result" ] || {
    echo "FAIL H2B7-LAMBDA-LIFECYCLE: execution changed $lambda_name"
    exit 1
  }
done
[ "$(grep -E '^  \(func \$mdk_wctor_Pair ' "$INPUT_WORK/lambda-p1.wat" | wc -l | tr -d '[:space:]')" -eq 1 ] &&
  [ "$(grep -E '^  \(func \$mdk_wctor_Pair ' "$INPUT_WORK/lambda-u.wat" | wc -l | tr -d '[:space:]')" -eq 1 ] &&
  [ "$(grep -E '^  \(func \$mdk_wctor_Pair ' "$INPUT_WORK/lambda-p2.wat" | wc -l | tr -d '[:space:]')" -eq 1 ] || {
  echo "FAIL H2B7-NAMED-WRAPPER-DEDUPE: duplicate Pair uses must define one wrapper"
  exit 1
}
lambda_elem_declare() {
  grep -E '^  \(elem declare func ' "$1"
}
[ "$(lambda_elem_declare "$INPUT_WORK/lambda-p1.wat")" = '  (elem declare func $mdk_pap $mdk_wctor_Pair $mdk_lam0)' ] &&
  [ "$(lambda_elem_declare "$INPUT_WORK/lambda-u.wat")" = '  (elem declare func $mdk_pap $mdk_wctor_Pair $mdk_lam0 $mdk_lam1)' ] &&
  [ "$(lambda_elem_declare "$INPUT_WORK/lambda-p2.wat")" = '  (elem declare func $mdk_pap $mdk_wctor_Pair $mdk_lam0)' ] || {
  echo "FAIL H2B7-ELEM-DECLARE-ORDER: exact function-reference membership/order changed"
  exit 1
}
[ "$(wc -l < "$INPUT_WORK/lambda-census.events")" -eq 1 ] &&
  grep -F $'val lambdaIntentionalGap\tunbound variable '\''missingLambdaCensus' "$INPUT_WORK/lambda-census.events" >/dev/null || {
  echo "FAIL H2B7-LAMBDA-LIFECYCLE: census event attribution"
  exit 1
}

[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

WORK="$(mktemp -d)"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$INPUT_WORK" "$WORK" "$RESULTS"' EXIT

# X-W.H2b.2: one process emits strict P, record U, a non-vacuous census, then
# strict P again. The exact payload/segment table makes this fail independently
# for a suppressed id increment, append, or a renamed ambient authority.
STRING_OUT="$($EMITBIN --reemit-string-state)" || {
  echo "FAIL wasm typed same-process string-segment lifecycle harness"
  exit 1
}
STRING_MARKERS="$(printf '%s\n' "$STRING_OUT" | awk '/^STRING_(P1|RECORD_U|CENSUS_EVENTS|P2)_(BEGIN|END)$/ { print }')"
STRING_EXPECTED_MARKERS="$(printf 'STRING_P1_BEGIN\nSTRING_P1_END\nSTRING_RECORD_U_BEGIN\nSTRING_RECORD_U_END\nSTRING_CENSUS_EVENTS_BEGIN\nSTRING_CENSUS_EVENTS_END\nSTRING_P2_BEGIN\nSTRING_P2_END')"
[ "$STRING_MARKERS" = "$STRING_EXPECTED_MARKERS" ] || {
  echo "FAIL wasm typed string-state lifecycle: expected exactly eight ordered markers"
  printf '  observed markers:\n%s\n' "${STRING_MARKERS:-<none>}"
  exit 1
}
string_capture() {
  awk -v begin="$1" -v end="$2" '
    $0 == begin { capture = 1; next }
    $0 == end { exit }
    capture { print }
  ' <<<"$STRING_OUT"
}
string_capture STRING_P1_BEGIN STRING_P1_END > "$WORK/string-p1.wat"
string_capture STRING_RECORD_U_BEGIN STRING_RECORD_U_END > "$WORK/string-u.wat"
string_capture STRING_CENSUS_EVENTS_BEGIN STRING_CENSUS_EVENTS_END > "$WORK/string-census.events"
string_capture STRING_P2_BEGIN STRING_P2_END > "$WORK/string-p2.wat"
for string_capture_file in string-p1.wat string-u.wat string-census.events string-p2.wat; do
  [ -s "$WORK/$string_capture_file" ] || {
    echo "FAIL wasm typed string-state lifecycle: empty $string_capture_file"
    exit 1
  }
done
cmp -s "$WORK/string-p1.wat" "$WORK/string-p2.wat" || {
  echo "FAIL wasm typed string-state lifecycle: P changed after record U and census"
  exit 1
}
cmp -s "$WORK/string-p1.wat" "$WORK/string-u.wat" && {
  echo "FAIL wasm typed string-state lifecycle: P/U positive control did not differ"
  exit 1
}
# Check the segment namespace before parsing so duplicate or missing declarations
# fail at this ownership assertion rather than being masked by wasm-tools.
for string_spec in "string-p1 11" "string-u 2" "string-p2 11"; do
  string_name="${string_spec% *}"
  string_count="${string_spec#* }"
  string_ids="$(awk '/^[[:space:]]*\(data \$strseg_[0-9]+ "/ { id = $0; sub(/^.*\$strseg_/, "", id); sub(/[[:space:]].*$/, "", id); print id }' "$WORK/$string_name.wat")"
  expected_ids="$(awk -v count="$string_count" 'BEGIN { for (i = 0; i < count; i++) print i }')"
  [ "$string_ids" = "$expected_ids" ] || {
    echo "FAIL wasm typed string-state lifecycle: $string_name segment ids/cardinality changed"
    printf '%s\n' "$string_ids"
    exit 1
  }
done
for string_wat in string-p1 string-u string-p2; do
  wasm-tools parse "$WORK/$string_wat.wat" -o "$WORK/$string_wat.wasm" || {
    echo "FAIL wasm typed string-state lifecycle: wasm-tools parse $string_wat"
    exit 1
  }
  wasm-tools validate --features=all "$WORK/$string_wat.wasm" || {
    echo "FAIL wasm typed string-state lifecycle: wasm-tools validate $string_wat"
    exit 1
  }
done
if ! STRING_P_RESULT="$($NODE "$RUNJS" "$WORK/string-p1.wasm" 2>"$WORK/string-p1.run.err")"; then
  echo "FAIL wasm typed string-state lifecycle: strict P execution failed"
  cat "$WORK/string-p1.run.err"
  exit 1
fi
[ ! -s "$WORK/string-p1.run.err" ] || {
  echo "FAIL wasm typed string-state lifecycle: strict P wrote stderr"
  cat "$WORK/string-p1.run.err"
  exit 1
}
[ "$STRING_P_RESULT" = "71" ] || {
  echo "FAIL wasm typed string-state lifecycle: strict P output was $STRING_P_RESULT"
  exit 1
}
if ! STRING_U_RESULT="$($NODE "$RUNJS" "$WORK/string-u.wasm" 2>"$WORK/string-u.run.err")"; then
  echo "FAIL wasm typed string-state lifecycle: record U execution failed"
  cat "$WORK/string-u.run.err"
  exit 1
fi
[ ! -s "$WORK/string-u.run.err" ] || {
  echo "FAIL wasm typed string-state lifecycle: record U wrote stderr"
  cat "$WORK/string-u.run.err"
  exit 1
}
[ "$STRING_U_RESULT" = "82" ] || {
  echo "FAIL wasm typed string-state lifecycle: record U output was $STRING_U_RESULT"
  exit 1
}
[ "$(wc -l < "$WORK/string-census.events")" -eq 2 ] || {
  echo "FAIL wasm typed string-state lifecycle: census was vacuous or incomplete"
  exit 1
}
sed -n '1p' "$WORK/string-census.events" | grep -F $'val gapA\tunbound variable '\''missingGapA' >/dev/null &&
  sed -n '2p' "$WORK/string-census.events" | grep -F $'val gapB\tunbound variable '\''missingGapB' >/dev/null || {
    echo "FAIL wasm typed string-state lifecycle: census event order changed"
    exit 1
  }
string_segments() {
  awk '
    /^[[:space:]]*\(data \$strseg_[0-9]+ "/ {
      seg_id = $0
      sub(/^.*\$strseg_/, "", seg_id)
      sub(/[[:space:]].*$/, "", seg_id)
      payload = $0
      sub(/^.*\$strseg_[0-9]+ "/, "", payload)
      sub(/"\)$/, "", payload)
      print seg_id "\t" payload
    }
  ' "$1"
}
string_references() {
  awk '
    /array\.new_data \$u8arr \$strseg_[0-9]+/ {
      seg_id = $0
      sub(/^.*\$strseg_/, "", seg_id)
      sub(/[^0-9].*$/, "", seg_id)
      print seg_id
    }
  ' "$1"
}
assert_string_segments() {
  local name="$1" wat="$2" expected_segments="$3" expected_refs="$4"
  string_segments "$wat" > "$WORK/$name.segments"
  string_references "$wat" > "$WORK/$name.refs"
  [ "$(cat "$WORK/$name.segments")" = "$expected_segments" ] || {
    echo "FAIL wasm typed string-state lifecycle: $name segment ids/payloads changed"
    cat "$WORK/$name.segments"
    exit 1
  }
  [ "$(cat "$WORK/$name.refs")" = "$expected_refs" ] || {
    echo "FAIL wasm typed string-state lifecycle: $name segment references are not exact/contiguous"
    cat "$WORK/$name.refs"
    exit 1
  }
}
P_SEGMENTS="$(printf '0\t\\70\\2d\\6e\\6f\\6e\\2d\\74\\61\\69\\6c\n1\t\\70\\2d\\6e\\6f\\6e\\2d\\74\\61\\69\\6c\\2d\\62\\6f\\64\\79\n2\t\\70\\2d\\6e\\6f\\6e\\2d\\74\\61\\69\\6c\\2d\\6f\\74\\68\\65\\72\n3\t\\70\\2d\\74\\61\\69\\6c\n4\t\\70\\2d\\74\\61\\69\\6c\\2d\\62\\6f\\64\\79\n5\t\\70\\2d\\74\\61\\69\\6c\\2d\\6f\\74\\68\\65\\72\n6\t\\70\\2d\\63\\6c\\61\\75\\73\\65\n7\t\\70\\2d\\63\\6c\\61\\75\\73\\65\\2d\\62\\6f\\64\\79\n8\t\\70\\2d\\63\\6c\\61\\75\\73\\65\\2d\\6f\\74\\68\\65\\72\n9\t\\70\\2d\\65\\78\\70\\72\n10\t\\70\\2d\\65\\78\\70\\72')"
P_REFS="$(printf '10\n9\n6\n7\n8\n3\n4\n5\n0\n1\n2')"
U_SEGMENTS="$(printf '0\t\\75\\2d\\6f\\74\\68\\65\\72\n1\t\\75\\2d\\65\\78\\70\\72')"
U_REFS="$(printf '1\n0')"
assert_string_segments string-p1 "$WORK/string-p1.wat" "$P_SEGMENTS" "$P_REFS"
assert_string_segments string-u "$WORK/string-u.wat" "$U_SEGMENTS" "$U_REFS"
assert_string_segments string-p2 "$WORK/string-p2.wat" "$P_SEGMENTS" "$P_REFS"

# X-W.H2b.4: strict P -> record U -> non-vacuous U census -> strict P. The two
# P request sites must produce one synthesized default definition in first-encounter
# order, and the extractor delimits that named function rather than a body constant.
DEFAULT_OUT="$($EMITBIN --reemit-default-state 2>"$WORK/default.emit.err")" || {
  echo "FAIL H2B4-DEFAULT-DEFS: same-process default-state harness"
  cat "$WORK/default.emit.err"
  exit 1
}
[ ! -s "$WORK/default.emit.err" ] || {
  echo "FAIL H2B4-DEFAULT-DEFS: harness wrote stderr"
  cat "$WORK/default.emit.err"
  exit 1
}
DEFAULT_MARKERS="$(printf '%s\n' "$DEFAULT_OUT" | awk '/^DEFAULT_(P1|RECORD_U|CENSUS_U_EVENTS|P2)_(BEGIN|END)$/ { print }')"
DEFAULT_EXPECTED_MARKERS="$(printf 'DEFAULT_P1_BEGIN\nDEFAULT_P1_END\nDEFAULT_RECORD_U_BEGIN\nDEFAULT_RECORD_U_END\nDEFAULT_CENSUS_U_EVENTS_BEGIN\nDEFAULT_CENSUS_U_EVENTS_END\nDEFAULT_P2_BEGIN\nDEFAULT_P2_END')"
[ "$DEFAULT_MARKERS" = "$DEFAULT_EXPECTED_MARKERS" ] || {
  echo "FAIL H2B4-DEFAULT-DEFS: expected exactly eight ordered markers"
  exit 1
}
default_capture() {
  awk -v begin="$1" -v end="$2" '
    $0 == begin { capture = 1; next }
    $0 == end { exit }
    capture { print }
  ' <<<"$DEFAULT_OUT"
}
default_capture DEFAULT_P1_BEGIN DEFAULT_P1_END > "$WORK/default-p1.wat"
default_capture DEFAULT_RECORD_U_BEGIN DEFAULT_RECORD_U_END > "$WORK/default-u.wat"
default_capture DEFAULT_CENSUS_U_EVENTS_BEGIN DEFAULT_CENSUS_U_EVENTS_END > "$WORK/default-census.events"
default_capture DEFAULT_P2_BEGIN DEFAULT_P2_END > "$WORK/default-p2.wat"
for default_capture_file in default-p1.wat default-u.wat default-census.events default-p2.wat; do
  [ -s "$WORK/$default_capture_file" ] || {
    echo "FAIL H2B4-DEFAULT-DEFS: empty $default_capture_file"
    exit 1
  }
done
cmp -s "$WORK/default-p1.wat" "$WORK/default-p2.wat" || {
  echo "FAIL H2B4-DEFAULT-DEFS: P changed after record U and census"
  exit 1
}
cmp -s "$WORK/default-p1.wat" "$WORK/default-u.wat" && {
  echo "FAIL H2B4-DEFAULT-DEFS: P/U positive control did not differ"
  exit 1
}
default_function() {
  awk -v name="$2" '
    $0 ~ "^  \\(func \\$" name "([[:space:]]|\\()" {
      capture = 1
    }
    capture {
      print
      opens = gsub(/\(/, "&")
      closes = gsub(/\)/, "&")
      depth += opens - closes
      if (depth == 0) exit
    }
  ' "$1"
}
for default_spec in "p1 PDefault 17" "u UDefault 29" "p2 PDefault 17"; do
  default_name="${default_spec%% *}"
  default_rest="${default_spec#* }"
  default_tag="${default_rest%% *}"
  default_constant="${default_rest#* }"
  default_wat="$WORK/default-$default_name.wat"
  default_symbol="mdk_default_synthDefault_$default_tag"
  [ "$(grep -F "(func \$$default_symbol" "$default_wat" | wc -l | tr -d '[:space:]')" -eq 1 ] || {
    echo "FAIL H2B4-DEFAULT-NAMES: $default_name must contain exactly one named synthesized default"
    exit 1
  }
  default_function "$default_wat" "$default_symbol" > "$WORK/default-$default_name.function"
  [ -s "$WORK/default-$default_name.function" ] &&
    grep -F "(func \$$default_symbol" "$WORK/default-$default_name.function" >/dev/null &&
    grep -F "i32.const $default_constant" "$WORK/default-$default_name.function" >/dev/null &&
    grep -F 'ref.i31' "$WORK/default-$default_name.function" >/dev/null || {
      echo "FAIL H2B4-DEFAULT-DEFS: $default_name generated default body constant changed"
      exit 1
    }
  wasm-tools parse "$default_wat" -o "$WORK/default-$default_name.wasm" || {
    echo "FAIL H2B4-DEFAULT-DEFS: wasm-tools parse $default_name"
    exit 1
  }
  wasm-tools validate --features=all "$WORK/default-$default_name.wasm" || {
    echo "FAIL H2B4-DEFAULT-DEFS: wasm-tools validate $default_name"
    exit 1
  }
  if ! DEFAULT_RUN_RESULT="$($NODE "$RUNJS" "$WORK/default-$default_name.wasm" 2>"$WORK/default-$default_name.run.err")"; then
    echo "FAIL H2B4-DEFAULT-DEFS: inert main execution failed for $default_name"
    cat "$WORK/default-$default_name.run.err"
    exit 1
  fi
  [ "$DEFAULT_RUN_RESULT" = "0" ] && [ ! -s "$WORK/default-$default_name.run.err" ] || {
    echo "FAIL H2B4-DEFAULT-DEFS: inert main output/stderr changed for $default_name"
    exit 1
  }
done
[ "$(wc -l < "$WORK/default-census.events")" -eq 1 ] &&
  grep -F $'val defaultCensusGap\tunbound variable '\''missingDefaultCensus' "$WORK/default-census.events" >/dev/null || {
    echo "FAIL H2B4-DEFAULT-DEFS: census event attribution changed"
    exit 1
  }

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
NODE_ABS="$(command -v "$NODE" 2>/dev/null || echo "$NODE")"
fixtures=("$FIXDIR"/*.mdk)
[ -e "${fixtures[0]}" ] || { echo "FAIL wasm typed gate: no fixtures in $FIXDIR"; exit 1; }
fixture_count="${#fixtures[@]}"
if ! printf '%s\n' "${fixtures[@]}" \
  | MEDAKA="$MEDAKA" EMITBIN="$EMITBIN" RUNTIME="$RUNTIME" NODE="$NODE_ABS" RUNJS="$RUNJS" \
    MEDAKA_EMITTER="${MEDAKA_EMITTER:-$EMITTER}" WASM_ORACLE_OPT="${WASM_ORACLE_OPT:-}" \
    WORKDIR="$WORK" RESULTDIR="$RESULTS" \
    xargs -P "$JOBS" -I{} bash "$0" --one {}; then
  echo "FAIL wasm typed gate: fixture worker pipeline"
  exit 1
fi

pass=0; fail=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

status_count=$((pass + fail))
[ "$status_count" -eq "$fixture_count" ] || {
  echo "FAIL wasm typed gate: expected $fixture_count statuses, found $status_count"
  exit 1
}

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
