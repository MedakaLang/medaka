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
EXPECTED_MODULE_REFS="$(printf '%s\n' \
  lamIdRef liftedFnsRef liftedNamesRef funcRefsRef liftedNamesSetW funcRefsSetW \
  useStrRef curBindRef useListRef useArrayRef useRefBoxRef useRecUpdateRef \
  useStrLeafRef useRngRef useHashRef useEPutRef useTrapImport useDivGuardRef \
  useFloatRef useFloatHashRef useMathRef useFloatRngRef useFloatStrRef \
  useStrSearchRef useValueCmpRef useValueArithRef numPolyLocalsRef useStrCodecRef \
   useCharFromCodeRef useCharClassRef useIORef useArgsRef useFileBytesRef \
   floatLocalsRef floatGlobalsRef tupleAritiesRef wTrmcCtxRef wDispCtxRef \
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
  echo "FAIL H2B4-AUTHORITY-SET: top-level Ref authority set changed"
  printf '  observed signatures:\n%s\n' "$ACTUAL_MODULE_REF_SIGS"
  printf '  observed definitions:\n%s\n' "$ACTUAL_MODULE_REF_DEFS"
  exit 1
fi
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

# Sprint 01 current-binding capture apparatus.  The sensitive rows deliberately
# retain their full direct stdout/stderr files for independent diagnostic
# adjudication; this gate checks only the observation protocol, never prose.
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
  local row="$1" rule="$2" marker="$3" setup="$4" expected prefix upper
  case "$row" in
    top) upper=TOP ;;
    lifted) upper=LIFT ;;
    no-writer) upper=NOWRITER ;;
    post-lift) upper=POSTLIFT ;;
    *) echo "FAIL $rule: unknown capture row"; exit 1 ;;
  esac
  "$EMITBIN" --capture-current-binding "$row" >"$INPUT_WORK/cbind-$row.out" 2>"$INPUT_WORK/cbind-$row.err"
  CBIND_ROW_STATUS=$?
  [ "$CBIND_ROW_STATUS" -ne 0 ] || { echo "FAIL $rule: strict emission unexpectedly succeeded"; exit 1; }
  [ -s "$INPUT_WORK/cbind-$row.err" ] || { echo "FAIL $rule: empty strict diagnostics"; exit 1; }
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
  [ -s "$INPUT_WORK/cbind-$row-record.events" ] || { echo "FAIL CBIND-RECORD-EVENTS: empty $row record events"; exit 1; }
  [ -s "$INPUT_WORK/cbind-$row-census.events" ] || { echo "FAIL CBIND-CENSUS-EVENTS: empty $row census events"; exit 1; }
  grep -F 'usage:' "$INPUT_WORK/cbind-$row.out" "$INPUT_WORK/cbind-$row.err" >/dev/null && { echo "FAIL $rule: usage error"; exit 1; }
  grep -Ei 'parse error|type error|type mismatch|setup error' "$INPUT_WORK/cbind-$row.out" "$INPUT_WORK/cbind-$row.err" >/dev/null && {
    echo "FAIL $rule: setup/type failure"
    exit 1
  }
  grep -E 'unbound variable|unsupported Core IR node|wasm W' "$INPUT_WORK/cbind-$row.err" >/dev/null || {
    echo "FAIL $rule: strict stderr lacks an emitter gap mechanism"
    exit 1
  }
}

cbind_abort_row top CBIND-TOP-ABORT CBIND_TOP_STRICT ''
cbind_abort_row lifted CBIND-LIFT-ABORT CBIND_LIFT_STRICT ''
cbind_abort_row no-writer CBIND-NOWRITER-ABORT CBIND_NOWRITER_STRICT $'CBIND_NOWRITER_SETUP_WAT_BEGIN\nCBIND_NOWRITER_SETUP_WAT_END\nCBIND_NOWRITER_SETUP_OK'
cbind_abort_row post-lift CBIND-POSTLIFT-ABORT CBIND_POSTLIFT_STRICT ''
if cmp -s "$INPUT_WORK/cbind-top.err" "$INPUT_WORK/cbind-lifted.err" &&
   cmp -s "$INPUT_WORK/cbind-top-record.events" "$INPUT_WORK/cbind-lifted-record.events"; then
  echo "FAIL CBIND-POSITIVE-DISTINCTION: top/lifted captures all identical"
  exit 1
fi

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
