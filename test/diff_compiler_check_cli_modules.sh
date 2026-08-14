#!/bin/sh
# DRIVER-COLLAPSE Phase 4 (OPTION A) capability gate: the real `medaka check` CLI
# now RESOLVES imports (loadProgram → multi-module typecheck), fixing the "native
# check is single-file" limitation.  This gate proves the new capability and that
# `check` AGREES with `build` on the SAME project (both route through the unified
# loader + elaborateModules path → the same hadTypeErrors verdict).
#
# It complements (does NOT duplicate):
#   • diff_compiler_check.sh         — single-file check_main host; no-import
#     byte-identity + UnknownModule for genuinely-missing imports (unchanged).
#   • diff_compiler_check_modules.sh — native multi typecheck vs the OCaml MULTI
#     oracle goldens (the import-aware path check now shares with run/build).
#   • diff_native_cli.sh check/*     — the CLI's no-import goldens (byte-identical).
#
# Drives ./medaka (must be freshly built — make medaka — see the diff_native_cli
# stale-binary footgun: this gate NEVER rebuilds it).
#
# Legs (all on a synthesized 2-file project with a cross-module import):
#   1. resolve:  `check main.mdk` resolves `import helper.{double}` — output names
#                the cross-module-typed binding and emits NO `UnknownModule`.
#   2. exit0:    a well-typed import-bearing project exits 0.
#   3. type-err: a type-error import-bearing project emits a TYPE ERROR and exits 1.
#   4. agree:    on that type-error project, `build` ALSO rejects (exit 1) — check
#                and build agree via the unified path.
#
# Usage:  sh test/diff_compiler_check_cli_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }
strip_unit() { sed '$ s/0$//'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# A small 2-file project: main imports a public helper from a sibling module.
cat > "$TMP/helper.mdk" <<'EOF'
export double : Int -> Int
double x = x + x
EOF
cat > "$TMP/good.mdk" <<'EOF'
import helper.{double}
quad : Int -> Int
quad x = double (double x)
main = println (quad 3)
EOF
cat > "$TMP/bad.mdk" <<'EOF'
import helper.{double}
bad : Int
bad = double "x"
EOF

# 1. resolve: import resolved (quad typed) AND no UnknownModule diagnostic.
good_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/good.mdk" 2>/dev/null | strip_unit)"
good_code=$?
case "$good_out" in
  *UnknownModule*) fail=$((fail+1)); printf 'FAIL resolve/import (still UnknownModule: %s)\n' "$good_out" ;;
  *"quad : Int -> Int"*) pass=$((pass+1)); printf 'ok   resolve/import (cross-module reference typed)\n' ;;
  *) fail=$((fail+1)); printf 'FAIL resolve/import (no quad scheme: [%s])\n' "$good_out" ;;
esac

# 2. exit0: well-typed import-bearing project exits 0.
MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/good.mdk" >/dev/null 2>&1
if [ "$?" -eq 0 ]; then pass=$((pass+1)); printf 'ok   exit0/good\n'
else fail=$((fail+1)); printf 'FAIL exit0/good (exit %d)\n' "$?"; fi

# 3. type-err: import-bearing type error → a LOCATED diagnostic + exit 1.
#    (Imported-module diagnostics fix): the multi-module CLI `check` now renders the
#    accumulated per-module diagnostics LOCATED (`file:L:C: message` + caret), the
#    same surface `--json` mirrors, instead of the old loc-free `TYPE ERROR: …`.  We
#    require the entry error to carry its `bad.mdk:LINE:COL:` location AND the message.
bad_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/bad.mdk" 2>/dev/null)"
bad_code=$?
case "$bad_out" in
  *bad.mdk:*:*:*"Type mismatch"*) if [ "$bad_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   type-err/bad (located file:L:C diagnostic, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL type-err/bad (located but exit %d)\n' "$bad_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL type-err/bad (no located diagnostic: [%s])\n' "$bad_out" ;;
esac

# 4. agree: build rejects the SAME type-error project (exit 1) — check==build.
MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/bad.mdk" -o "$TMP/bad.out" >/dev/null 2>&1
build_code=$?
if [ "$build_code" -ne 0 ] && [ ! -x "$TMP/bad.out" ]; then
  pass=$((pass+1)); printf 'ok   agree/build-rejects (check & build both reject)\n'
else
  fail=$((fail+1)); printf 'FAIL agree/build-rejects (build exit %d, binary present=%s)\n' "$build_code" "$([ -x "$TMP/bad.out" ] && echo yes || echo no)"
fi

# 5. numlit-soundness (#11 cross-module hole): a numeric-literal arg to an IMPORTED
#    function, unified through a polymorphic param with a NON-Num type, MUST be
#    rejected (the literal's Num obligation was being silently dropped on the
#    cross-module path → over-accept).  Since Chunk D (Num mis-framing reframe) the
#    rejection reads as the clearer `Type mismatch: Int literal vs List (List Int)`
#    (a literal forced to a ground non-Num type is a structural mismatch), not the
#    older `No impl of Num for …`; either wording proves the obligation is enforced
#    — the gate accepts both and only requires the reject (exit 1).  Legs 1–2 (a
#    legit Int-defaulting cross-module call) still pass, guarding over-strictness.
cat > "$TMP/numlib.mdk" <<'EOF'
export g : Ord a => a -> List a -> Bool
g x ys = True
EOF
cat > "$TMP/numbad.mdk" <<'EOF'
import numlib.{g}
main = println (g [1, 2] 5)
EOF
num_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/numbad.mdk" 2>/dev/null)"
num_code=$?
case "$num_out" in
  *"No impl of Num for List (List Int)"*|*"Int literal vs List (List Int)"*) if [ "$num_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   numlit-soundness (cross-module literal Num obligation enforced)\n'
                  else fail=$((fail+1)); printf 'FAIL numlit-soundness (rejected but exit %d)\n' "$num_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL numlit-soundness (cross-module Num literal hole: [%s])\n' "$num_out" ;;
esac

# 6. cross-module superinterface (WS-1a over-rejection regression guard).  An
#    `impl Monoid Color` in the ENTRY whose required superinterface `impl
#    Semigroup Color` lives in an IMPORTED module must be ACCEPTED — instances are
#    global, so the super impl exists even though it isn't `export`-marked (and
#    even when it is).  Before the allImplDecls accumulator fix, the multi-module
#    superinterface existence query only saw `accData ++ prog` (which drops
#    imported impls) → false `requires a superinterface impl '… Semigroup …',
#    which is missing`.  Legs: (a) imported non-export super → accept; (b) NO
#    super anywhere → still reject (the under-rejection guard for WS-1a itself).
cat > "$TMP/sg.mdk" <<'EOF'
public export data Color = Red | Green

impl Semigroup Color where
  append x y = x
EOF
cat > "$TMP/mono_ok.mdk" <<'EOF'
import sg.{Color(..)}

impl Monoid Color where
  empty = Red

main = println "ok"
EOF
sup_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/mono_ok.mdk" 2>/dev/null)"
sup_code=$?
case "$sup_out" in
  *superinterface*) fail=$((fail+1)); printf 'FAIL super-xmod/accept (false reject: [%s])\n' "$sup_out" ;;
  *) if [ "$sup_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   super-xmod/accept (imported super impl satisfies the requires)\n'
     else fail=$((fail+1)); printf 'FAIL super-xmod/accept (exit %d: [%s])\n' "$sup_code" "$sup_out"; fi ;;
esac

cat > "$TMP/nosup.mdk" <<'EOF'
public export data Color = Red | Green
EOF
cat > "$TMP/mono_bad.mdk" <<'EOF'
import nosup.{Color(..)}

impl Monoid Color where
  empty = Red

main = println "ok"
EOF
nosup_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/mono_bad.mdk" 2>/dev/null)"
nosup_code=$?
case "$nosup_out" in
  *"requires a superinterface 'impl Semigroup Color', which is missing"*)
    if [ "$nosup_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   super-xmod/reject (no super anywhere still rejected)\n'
    else fail=$((fail+1)); printf 'FAIL super-xmod/reject (rejected but exit %d)\n' "$nosup_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL super-xmod/reject (under-rejection regressed: [%s])\n' "$nosup_out" ;;
esac

# 7b. cross-module prelude-Ord obligation (Bug B regression guard).  An import-
#     bearing program whose entry uses an `Ord`-constrained operation on a prelude
#     type (`Int`) records a (Ord, Int) CALL obligation.  checkModuleFullImpl's
#     checkCallObligations matched it against `implDecls ++ prog` only, which OMITS
#     `accData` (the prelude's `impl Ord Int`) → spurious `No impl of Ord for Int`.
#     The fix threads `accData` into the call-obligation impl universe.  This MUST
#     be CLEAN (exit 0), matching run/build.
cat > "$TMP/ordlib.mdk" <<'EOF'
export pick : Ord a => a -> a -> a
pick x y = if x < y then y else x
EOF
cat > "$TMP/orduse.mdk" <<'EOF'
import ordlib.{pick}
main = println (pick 3 7)
EOF
ord_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/orduse.mdk" 2>/dev/null)"
ord_code=$?
case "$ord_out" in
  *"No impl of Ord"*) fail=$((fail+1)); printf 'FAIL ord-xmod (spurious prelude-Ord reject: [%s])\n' "$ord_out" ;;
  *) if [ "$ord_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   ord-xmod (prelude Ord Int obligation satisfied cross-module)\n'
     else fail=$((fail+1)); printf 'FAIL ord-xmod (exit %d: [%s])\n' "$ord_code" "$ord_out"; fi ;;
esac

# 8. global cross-module coherence (D3 / WS-2 part-2).  Two DIFFERENT modules each
#    define `impl C T` for the SAME instance: each module is LOCALLY coherent, but
#    jointly incoherent (silent dispatch ambiguity — cuseM2 would print cuseM1's
#    result).  Per-module coherence accepts this; the global check must REJECT,
#    naming BOTH owning modules.
cat > "$TMP/cohbase.mdk" <<'EOF'
public export data CT = CT1
export interface CIface a where
  csh : a -> Int
EOF
cat > "$TMP/cohm1.mdk" <<'EOF'
import cohbase.{CT(..), CIface(..), csh}
export impl CIface CT where
  csh x = 1
export cuseM1 : Int
cuseM1 = csh CT1
EOF
cat > "$TMP/cohm2.mdk" <<'EOF'
import cohbase.{CT(..), CIface(..), csh}
export impl CIface CT where
  csh x = 2
export cuseM2 : Int
cuseM2 = csh CT1
EOF
cat > "$TMP/cohtop.mdk" <<'EOF'
import cohm1.{cuseM1}
import cohm2.{cuseM2}
main =
  println cuseM1
  println cuseM2
EOF
coh_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/cohtop.mdk" 2>/dev/null)"
coh_code=$?
case "$coh_out" in
  *Conflicting*)
    case "$coh_out" in *cohm1*) m1seen=yes ;; *) m1seen=no ;; esac
    case "$coh_out" in *cohm2*) m2seen=yes ;; *) m2seen=no ;; esac
    if [ "$coh_code" -eq 1 ] && [ "$m1seen" = yes ] && [ "$m2seen" = yes ]; then
      pass=$((pass+1)); printf 'ok   coh-xmod/conflict (rejected, names both modules)\n'
    else
      fail=$((fail+1)); printf 'FAIL coh-xmod/conflict (exit %d m1=%s m2=%s: [%s])\n' "$coh_code" "$m1seen" "$m2seen" "$coh_out"
    fi ;;
  *) fail=$((fail+1)); printf 'FAIL coh-xmod/conflict (not rejected as conflict: [%s])\n' "$coh_out" ;;
esac

# 9. benign DIAMOND: ONE shared impl in `dbase`, imported by m1 and m2 → ACCEPT.
#    Imports do NOT copy impl decls, so the joint set has a single entry — no
#    false overlap.  This is the over-rejection guard for the global check.
cat > "$TMP/dbase.mdk" <<'EOF'
public export data DT = DT1
export interface DIface a where
  dsh : a -> Int
export impl DIface DT where
  dsh x = 9
EOF
cat > "$TMP/dm1.mdk" <<'EOF'
import dbase.{DT(..), DIface(..), dsh}
export duseM1 : Int
duseM1 = dsh DT1
EOF
cat > "$TMP/dm2.mdk" <<'EOF'
import dbase.{DT(..), DIface(..), dsh}
export duseM2 : Int
duseM2 = dsh DT1
EOF
cat > "$TMP/dtop.mdk" <<'EOF'
import dm1.{duseM1}
import dm2.{duseM2}
main =
  println duseM1
  println duseM2
EOF
dia_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/dtop.mdk" 2>/dev/null)"
dia_code=$?
case "$dia_out" in
  *Conflicting*) fail=$((fail+1)); printf 'FAIL coh-xmod/diamond (benign shared impl falsely rejected: [%s])\n' "$dia_out" ;;
  *) if [ "$dia_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   coh-xmod/diamond (single shared impl accepted)\n'
     else fail=$((fail+1)); printf 'FAIL coh-xmod/diamond (exit %d: [%s])\n' "$dia_code" "$dia_out"; fi ;;
esac

# 9. P0-18 importer-shadow on a NO-IMPL receiver.  `size` is IMPORTED from `impprov`
#    and shadows the LOCAL interface method `Sizeable.size`.  `size (Box 3)` must
#    dispatch to the local `impl Sizeable Box` (3); `size 3` (Int, NO impl) must fall
#    back to the imported standalone (4).  Before the fix `check` REJECTED (`No impl of
#    Sizeable for Int`) and `build` PANICKED, while `run` correctly returned the
#    standalone — the imported shadow's bare name was invisible to the emit-path shadow
#    detection (mangled) AND its no-impl obligation was not skipped on the check path.
#    check must ACCEPT and build must AGREE (dispatch 3 then standalone 4).
cat > "$TMP/impprov.mdk" <<'EOF'
export size : Int -> Int
size n = n + 1
EOF
cat > "$TMP/impmain.mdk" <<'EOF'
import impprov.{size}

interface Sizeable a where
  size : a -> Int

data Box = Box Int

impl Sizeable Box where
  size (Box n) = n

main =
  println (size (Box 3))
  println (size 3)
EOF
imp_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/impmain.mdk" 2>/dev/null)"
imp_code=$?
case "$imp_out" in
  *"No impl"*) fail=$((fail+1)); printf 'FAIL importer-shadow/check (spurious no-impl reject: [%s])\n' "$imp_out" ;;
  *) if [ "$imp_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   importer-shadow/check (imported shadow on no-impl receiver accepted)\n'
     else fail=$((fail+1)); printf 'FAIL importer-shadow/check (exit %d: [%s])\n' "$imp_code" "$imp_out"; fi ;;
esac
# build AGREEMENT: the same project must build AND run to `3` then `4`.
if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/impmain.mdk" -o "$TMP/imp.bin" >/dev/null 2>&1 && [ -x "$TMP/imp.bin" ]; then
  imp_bld="$("$TMP/imp.bin" 2>/dev/null | tr '\n' ',')"
  if [ "$imp_bld" = "3,4," ]; then pass=$((pass+1)); printf 'ok   importer-shadow/build (dispatch 3 + standalone 4)\n'
  else fail=$((fail+1)); printf 'FAIL importer-shadow/build (got [%s], want [3,4,])\n' "$imp_bld"; fi
else fail=$((fail+1)); printf 'FAIL importer-shadow/build (native build failed)\n'; fi

# 10. THE S2 INVERSION (SHADOW-SEMANTICS row 14 / cell d8) — DEFINER shadow with an
#     IMPORTED interface+impl.  The CONSUMER defines the standalone `size : Int -> Int`
#     and IMPORTS the interface `Sizeable` + type `Box(..)` + its impl from `dprov`.
#
#     ⚠️ RE-PINNED 2026-07-14, ACCEPT(3,4) -> located REJECT.  This leg was added by
#     ebb8ee90 (P0-19 batch 2) to assert the OLD S2: "the impl universe is GLOBAL, so
#     `size (Box 3)` must DISPATCH to the imported `impl Sizeable Box`".  The inversion
#     abolishes the rule that leg encoded — a DEFINER shadow is now the standalone,
#     unconditionally, and the impl universe is never queried.  So `size (Box 3)` types
#     against the consumer's own `size : Int -> Int` and REJECTS `Type mismatch: Int vs
#     Box` at the call site, on check AND run AND build.  This is a DELIBERATE revert of
#     a two-day-old intentional fix, not a regression — see the d8 row in
#     test/diff_compiler_shadow_semantics.sh.
#
#     S6 still holds, but VACUOUSLY: where the interface and impl live cannot change the
#     outcome, because the outcome no longer depends on them.  The all-local cell d2
#     rejects identically, which is the point.
#
#     ⚠️ The IMPORTER-shadow leg immediately above (#9) is the Fork-1 control and MUST
#     still ACCEPT + dispatch (3,4): an `import` is a SIBLING scope, not an inner one,
#     so it does NOT shadow.  If #9 and #10 ever agree, the inversion has leaked.
cat > "$TMP/dprov.mdk" <<'EOF'
export interface Sizeable a where
  size : a -> Int

public export data Box = Box Int

export impl Sizeable Box where
  size (Box n) = n
EOF
cat > "$TMP/dmain.mdk" <<'EOF'
import dprov.{Sizeable, Box(..)}

size : Int -> Int
size n = n + 1

main =
  println (size (Box 3))
  println (size 3)
EOF
dfn_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/dmain.mdk" 2>&1)"
dfn_code=$?
# The standalone WINS: `size (Box 3)` must be a LOCATED reject against `size : Int -> Int`.
case "$dfn_out" in
  *"dmain.mdk:7:10: Type mismatch: Int vs Box"*)
    if [ "$dfn_code" -ne 0 ]; then pass=$((pass+1)); printf 'ok   definer-shadow-xmod/check (S2 inversion: standalone wins, located reject at the call)\n'
    else fail=$((fail+1)); printf 'FAIL definer-shadow-xmod/check (diagnosed but exit 0)\n'; fi ;;
  *) fail=$((fail+1)); printf 'FAIL definer-shadow-xmod/check (want located "Int vs Box" at 7:10, got exit %d: [%s])\n' "$dfn_code" "$dfn_out" ;;
esac
# build AGREEMENT (S7): the same project must FAIL to build, and emit no binary.
if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/dmain.mdk" -o "$TMP/dfn.bin" >/dev/null 2>&1 && [ -x "$TMP/dfn.bin" ]; then
  fail=$((fail+1)); printf 'FAIL definer-shadow-xmod/build (built a binary; the standalone-domain reject must stop it)\n'
else
  pass=$((pass+1)); printf 'ok   definer-shadow-xmod/build (S2 inversion: rejected, no binary — agrees with check)\n'
fi

# 11. IMPORTED-MODULE diagnostics (the regression this gate's fix targets).  A type
#     error in an IMPORTED module (badhelper.mdk) used to be invisible on the very
#     command the deflection told you to run: `check` reported the entry only (loc-
#     free), `run`/`build` deflected to "type error in main.mdk", yet `--json` DID
#     carry the imported error with a real range.  All THREE human commands must now
#     surface the IMPORTED module's error LOCATED (badhelper.mdk:L:C:), matching JSON.
cat > "$TMP/badhelper.mdk" <<'EOF'
export badFn : Int -> Int
badFn x = x + "notanint"
EOF
cat > "$TMP/impuse.mdk" <<'EOF'
import badhelper.{badFn}
main = println (badFn 3)
EOF
imp_chk="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/impuse.mdk" 2>&1)"
imp_chk_code=$?
case "$imp_chk" in
  *badhelper.mdk:*:*:*"Type mismatch"*) if [ "$imp_chk_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   imported-diag/check (imported error located, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL imported-diag/check (located but exit %d)\n' "$imp_chk_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL imported-diag/check (imported error not located: [%s])\n' "$imp_chk" ;;
esac
imp_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/impuse.mdk" 2>&1)"
imp_run_code=$?
case "$imp_run" in
  *badhelper.mdk:*:*:*"Type mismatch"*) if [ "$imp_run_code" -ne 0 ]; then pass=$((pass+1)); printf 'ok   imported-diag/run (imported error located, nonzero exit)\n'
                  else fail=$((fail+1)); printf 'FAIL imported-diag/run (located but exit 0)\n'; fi ;;
  *) fail=$((fail+1)); printf 'FAIL imported-diag/run (imported error not located: [%s])\n' "$imp_run" ;;
esac
imp_bld="$(MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/impuse.mdk" -o "$TMP/impuse.out" 2>&1)"
imp_bld_code=$?
case "$imp_bld" in
  *badhelper.mdk:*:*:*"Type mismatch"*) if [ "$imp_bld_code" -ne 0 ] && [ ! -x "$TMP/impuse.out" ]; then pass=$((pass+1)); printf 'ok   imported-diag/build (imported error located, no binary)\n'
                  else fail=$((fail+1)); printf 'FAIL imported-diag/build (located but built? exit %d)\n' "$imp_bld_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL imported-diag/build (imported error not located: [%s])\n' "$imp_bld" ;;
esac

# 12. IMPORTED-MODULE *RESOLVE* diagnostics (#41 — the RESOLVE-path analog of leg 11).
#     Leg 11 covers imported TYPE errors (routed through analyzeProject, which already
#     bucketed by file); RESOLVE errors take a DIFFERENT CLI path
#     (resolveModulesToHumane*) that applied a SINGLE `target` fallback to EVERY
#     module's errors, so an imported module's `Unbound variable` printed the ENTRY
#     file's path (and, for a >entry-length file, an entry line number that does not
#     exist).  The per-module path map (resolveModulesToHumaneByPath) must now
#     attribute the imported module's resolve error to ITS OWN file.
cat > "$TMP/reshelper.mdk" <<'EOF'
export rh : Int -> Int
rh x = x + missingName
EOF
cat > "$TMP/resuse.mdk" <<'EOF'
import reshelper.{rh}
main = println (rh 3)
EOF
res_chk="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/resuse.mdk" 2>&1)"
res_chk_code=$?
case "$res_chk" in
  *resuse.mdk:*"Unbound variable"*) fail=$((fail+1)); printf 'FAIL imported-resolve/attr (#41 regressed: imported error mislabeled as entry: [%s])\n' "$res_chk" ;;
  *reshelper.mdk:*:*:*"Unbound variable"*) if [ "$res_chk_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   imported-resolve/attr (#41: imported resolve error located at its OWN file)\n'
                  else fail=$((fail+1)); printf 'FAIL imported-resolve/attr (located but exit %d)\n' "$res_chk_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL imported-resolve/attr (imported resolve error not located: [%s])\n' "$res_chk" ;;
esac

# 12b. THE SAME RESOLVE ERROR THROUGH `run` AND `build` (#186 / #1360 — the build/run
#      half of #41).  #41's per-module `pathMap` was wired into `checkRoute` ONLY;
#      `typecheckGateRoute` (build) and the run route kept the single-`target`
#      fallback renderer, so an IMPORTED module's resolve error printed under the
#      ENTRY file's name.  Measured before the fix, on this very fixture:
#        check : reshelper.mdk:2:11:  (correct)
#        run   : resuse.mdk:2:11:     (real line/col, WRONG file)
#        build : resuse.mdk:1:0:      (wrong file AND collapsed placeholder loc —
#                                      build additionally used the non-located
#                                      loader `loadProgramE`)
#      So the assertion is deliberately BOTH-SIDED: the diagnostic must name the
#      dep file with a real L:C, and must NOT name the entry file at all.  A gate
#      that only checked "mentions reshelper.mdk" would have passed on the `build`
#      arm the day it printed `resuse.mdk:1:0` with no reshelper mention at all —
#      hence the explicit entry-file rejection arm first in each case.
res_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/resuse.mdk" 2>&1)"
res_run_code=$?
case "$res_run" in
  *resuse.mdk:*"Unbound variable"*) fail=$((fail+1)); printf 'FAIL imported-resolve/run (#186: imported resolve error mislabeled as entry: [%s])\n' "$res_run" ;;
  *reshelper.mdk:*:*:*"Unbound variable"*) if [ "$res_run_code" -ne 0 ]; then pass=$((pass+1)); printf 'ok   imported-resolve/run (#186: located at its OWN file)\n'
                  else fail=$((fail+1)); printf 'FAIL imported-resolve/run (located but exit 0)\n'; fi ;;
  *) fail=$((fail+1)); printf 'FAIL imported-resolve/run (imported resolve error not located: [%s])\n' "$res_run" ;;
esac
res_bld="$(MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/resuse.mdk" -o "$TMP/resuse.out" 2>&1)"
res_bld_code=$?
case "$res_bld" in
  *resuse.mdk:*"Unbound variable"*) fail=$((fail+1)); printf 'FAIL imported-resolve/build (#186: imported resolve error mislabeled as entry: [%s])\n' "$res_bld" ;;
  *reshelper.mdk:*:*:*"Unbound variable"*) if [ "$res_bld_code" -ne 0 ] && [ ! -x "$TMP/resuse.out" ]; then pass=$((pass+1)); printf 'ok   imported-resolve/build (#186: located at its OWN file, no binary)\n'
                  else fail=$((fail+1)); printf 'FAIL imported-resolve/build (located but built? exit %d)\n' "$res_bld_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL imported-resolve/build (imported resolve error not located: [%s])\n' "$res_bld" ;;
esac

# 12c. THE POSITION MUST BE REAL, NOT A PLACEHOLDER (#1360, `build`'s second half).
#      `build`'s gate used to load with the non-located `loadProgramE`, collapsing
#      EVERY span to 1:0 — a defect visible even when the FILENAME happens to be
#      right, which 12b's dep-file assertion is blind to.  So this leg puts the
#      only resolve error in the ENTRY module and asserts `build` reports the same
#      `file:L:C:` prefix `check` does.  It also covers 12b's blind spot in the
#      other direction: 12b's reject arm is `*resuse.mdk:*`, so "an ENTRY error
#      wrongly attributed to the DEP" is untested there.
#
#      ⚠️ THE IMPORT MUST BE A CLEAN MODULE.  This gate uses ONE `mktemp -d` for
#      every leg (`trap ... EXIT`), so `$TMP/reshelper.mdk` — written by leg 12
#      with its own unbound `missingName` — is still on disk here.  Importing THAT
#      would make this leg a second dep-attribution test: the loader is
#      dependency-first (`visitModF` appends a module AFTER recursing into its
#      imports) and `resolveModulesErrorsByPathGo` concatenates in that order, so
#      the FIRST diagnostic line would be reshelper's, not the entry's, and the
#      entry-module case would silently go untested.  `helper.mdk` (written at the
#      top of this gate) is clean, so `nosuchName` is the only resolve error and
#      the first line is necessarily the entry's.
cat > "$TMP/entryres.mdk" <<'EOF'
import helper.{double}

main = println (nosuchName (double 3))
EOF
# ⚠️ Capture the WHOLE output, then take line 1 from the variable.  Piping the
# command itself into `head -1` would report head's exit status, so a failing
# build reads as exit 0 and the outcome assertion below could never fire.
ent_chk_all="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/entryres.mdk" 2>&1)"
ent_bld_all="$(MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/entryres.mdk" -o "$TMP/entryres.out" 2>&1)"
ent_bld_code=$?
ent_chk="$(printf '%s\n' "$ent_chk_all" | head -1)"
ent_bld="$(printf '%s\n' "$ent_bld_all" | head -1)"
ent_chk_pos="${ent_chk%%: *}"
ent_bld_pos="${ent_bld%%: *}"
# Assert the MESSAGE and the outcome too, not just prefix equality: if both arms
# emitted nothing, both prefixes would be empty and a bare equality check would
# report `ok` having proven nothing (12b asserts all three; so must this).
case "$ent_bld" in
  *entryres.mdk:*:*:*"Unbound variable"*) : ;;
  *) fail=$((fail+1)); printf 'FAIL entry-resolve/build-pos (entry resolve error not located at the entry: [%s])\n' "$ent_bld"; ent_bld_pos="<unasserted>" ;;
esac
case "$ent_bld_pos" in
  "<unasserted>") : ;;
  *:1:0) fail=$((fail+1)); printf 'FAIL entry-resolve/build-pos (#1360: placeholder loc 1:0 back: [%s])\n' "$ent_bld" ;;
  *) if [ "$ent_bld_pos" != "$ent_chk_pos" ]; then fail=$((fail+1)); printf 'FAIL entry-resolve/build-pos (check=[%s] build=[%s])\n' "$ent_chk_pos" "$ent_bld_pos"
     elif [ "$ent_bld_code" -eq 0 ] || [ -x "$TMP/entryres.out" ]; then fail=$((fail+1)); printf 'FAIL entry-resolve/build-pos (located but built? exit %d)\n' "$ent_bld_code"
     else pass=$((pass+1)); printf 'ok   entry-resolve/build-pos (#1360: build agrees with check on file:L:C, no binary)\n'; fi ;;
esac

# 13. ENTRY-PROJECT internal-extern trust (#42, POSITIVE).  A sibling module of the
#     entry, within the SAME `medaka.toml` project, legitimately calls an
#     internal-only kernel (`arrayGetUnsafe`).  Checking your OWN multi-module
#     project must NOT require `--allow-internal`: the entry project's own modules
#     are trusted exactly as stdlib is.  (Previously trusted ONLY stdlib, so this
#     flagged `internal-only primitive` unless the flag was passed.)  The trust
#     keys on the manifest — a `medaka.toml` marks this as a real project (a LOOSE
#     no-manifest file stays untrusted; that leg lives in
#     diff_compiler_internal_extern.sh).  Must ACCEPT (no internal-only error).
mkdir -p "$TMP/ownproj"
cat > "$TMP/ownproj/medaka.toml" <<'EOF'
name = "ownproj"
EOF
cat > "$TMP/ownproj/kern.mdk" <<'EOF'
export first : Array Int -> Int
first a = arrayGetUnsafe 0 a
EOF
cat > "$TMP/ownproj/kernuse.mdk" <<'EOF'
import kern.{first}
main = println (first (arrayFromList [1, 2, 3]))
EOF
kern_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/ownproj/kernuse.mdk" 2>&1)"
kern_code=$?
case "$kern_out" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL own-project-trust (#42 regressed: own sibling flagged internal-only: [%s])\n' "$kern_out" ;;
  *) if [ "$kern_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   own-project-trust (#42: entry-project sibling may use internal kernels)\n'
     else fail=$((fail+1)); printf 'FAIL own-project-trust (exit %d: [%s])\n' "$kern_code" "$kern_out"; fi ;;
esac

# 14. DECLARED-DEPENDENCY internal-extern trust (#42, SECURITY BOUNDARY / NEGATIVE).
#     The trust from leg 13 must NOT extend to a THIRD-PARTY dependency: a dep
#     declared in medaka.toml [dependencies] resolves to a root OUTSIDE the entry's
#     search roots, so its use of an internal-only kernel MUST still be REJECTED
#     (this is the whole point of the guard — an imported package cannot silently
#     reach for memory-unsafe primitives).  Rejected + attributed to the DEP's file.
mkdir -p "$TMP/depapp" "$TMP/depdep"
cat > "$TMP/depdep/medaka.toml" <<'EOF'
name = "depdep"
EOF
cat > "$TMP/depdep/k.mdk" <<'EOF'
export peek : Array Int -> Int
peek a = arrayGetUnsafe 0 a
EOF
cat > "$TMP/depapp/medaka.toml" <<'EOF'
name = "depapp"

[dependencies]
depdep = "../depdep"
EOF
cat > "$TMP/depapp/m.mdk" <<'EOF'
import depdep.k.{peek}
main = println (peek (arrayFromList [1, 2, 3]))
EOF
dep_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/depapp/m.mdk" 2>&1)"
dep_code=$?
case "$dep_out" in
  *k.mdk:*:*:*"internal-only primitive"*) if [ "$dep_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   dep-untrusted (#42 boundary: declared dep still rejected, located at dep file)\n'
                  else fail=$((fail+1)); printf 'FAIL dep-untrusted (rejected but exit %d)\n' "$dep_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL dep-untrusted (#42 boundary BROKEN: dep internal-extern not rejected: [%s])\n' "$dep_out" ;;
esac

# 15. #201 (letrec, MULTI-MODULE half).  A top-level `let rec` non-function binding
#     in an IMPORTED module was SILENTLY ACCEPTED — the flat single-file path runs
#     checkLetRecDecls but the multi-module body (checkModuleFullImpl) did not.  PR-A
#     hoists the pass into the module body, so the imported bad decl now rejects with
#     a LOCATED diagnostic (dep.mdk:L:C:) and exit 1.  The flat half is pinned by
#     test/run_check_agreement_fixtures/reject_toplevel_letrec_nonfunction.mdk.
cat > "$TMP/lrdep.mdk" <<'EOF'
export loop : Int
let rec loop = loop
EOF
cat > "$TMP/lruse.mdk" <<'EOF'
import lrdep.{loop}
main = println loop
EOF
lr_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/lruse.mdk" 2>&1)"
lr_code=$?
case "$lr_out" in
  *lrdep.mdk:*:*:*"is bound by 'let rec' but its right-hand side is not a function"*)
    if [ "$lr_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   letrec-xmod (#201: imported let-rec non-function located + rejected)\n'
    else fail=$((fail+1)); printf 'FAIL letrec-xmod (located but exit %d)\n' "$lr_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL letrec-xmod (#201 regressed: imported let-rec non-function not rejected: [%s])\n' "$lr_out" ;;
esac

# 16. #201 (effect-param, MULTI-MODULE half).  An atomic effect label given a
#     parameter in an IMPORTED module was SILENTLY ACCEPTED — the flat path runs
#     checkEffectParams, the multi-module body did not.  PR-A hoists the pass into
#     the module body, so the imported bad sig now rejects located + exit 1.  The
#     flat half is pinned by run_check_agreement_fixtures/reject_effect_param_atomic.
cat > "$TMP/effdep.mdk" <<'EOF'
effect Bar

export f : Int -> <Bar "x"> Int
f n = n
EOF
cat > "$TMP/effuse.mdk" <<'EOF'
import effdep.{f}
main = println (f 3)
EOF
eff_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/effuse.mdk" 2>&1)"
eff_code=$?
case "$eff_out" in
  *effdep.mdk:*:*:*"is atomic and takes no parameter"*)
    if [ "$eff_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   effect-param-xmod (#201: imported atomic-effect param located + rejected)\n'
    else fail=$((fail+1)); printf 'FAIL effect-param-xmod (located but exit %d)\n' "$eff_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL effect-param-xmod (#201 regressed: imported effect-param error not rejected: [%s])\n' "$eff_out" ;;
esac

# 17. CROSS-MODULE effect-domain population (#80 BREAK #3 guard / over-rejection).
#     Module A declares `effect MyEff Prefix`; module B uses `<MyEff "svc/*">` with a
#     VALID prefix parameter.  This MUST be ACCEPTED: PR-A populates effect domains
#     ONCE over the WHOLE import graph in the driver preamble (checkModulesPreamble /
#     elaborateModules) and stops resetState from re-seeding, so B sees A's declared
#     Prefix domain.  A naive per-module hoist of populateEffectDomains would wipe A's
#     domain before B, leaving only builtins → B would FALSELY reject `MyEff` as
#     atomic ("label 'MyEff' is atomic and takes no parameter").  So a spurious reject
#     here means the cross-module effect-domain population regressed.
cat > "$TMP/effprov.mdk" <<'EOF'
effect MyEff Prefix

export ping : Unit -> <MyEff "svc/*"> Int
ping _ = 0
EOF
cat > "$TMP/effok.mdk" <<'EOF'
import effprov.{ping}
main = println (ping ())
EOF
effok_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/effok.mdk" 2>&1)"
effok_code=$?
case "$effok_out" in
  *"is atomic and takes no parameter"*) fail=$((fail+1)); printf 'FAIL effect-xmod/accept (BREAK #3: cross-module effect domain not populated: [%s])\n' "$effok_out" ;;
  *) if [ "$effok_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   effect-xmod/accept (cross-module Prefix effect domain populated over the graph)\n'
     else fail=$((fail+1)); printf 'FAIL effect-xmod/accept (exit %d: [%s])\n' "$effok_code" "$effok_out"; fi ;;
esac

# 12. #674 CROSS-MODULE DUPLICATE PUBLIC CONSTRUCTOR.  Two modules each export a
#     ctor of the SAME NAME.  The check side (typecheck/exhaust, last-loaded-wins) and
#     the native mangler (per-unit, first-import-wins) used to DISAGREE on which one a
#     bare `Node`/`Box` binds — check accepted, run was right, the native build CRASHED
#     (E-NONEXHAUSTIVE-MATCH), and a bare `import` of the OTHER module wrongly rejected
#     a VALID program.  The fix: import-scope the check-side ctor tables + reject a
#     genuine cross-module ctor collision at resolve time.  Legs a–d below.
cat > "$TMP/x674a.mdk" <<'EOF'
public export data TA = Node Int
export ma : TA
ma = Node 111
EOF
cat > "$TMP/x674b.mdk" <<'EOF'
public export data TB = Node Int
export mb : TB
mb = Node 222
EOF
# 12a. AMBIGUOUS: importing BOTH `Node`-exporting modules and USING `Node` is a
#      hard resolve error (R-AMBIGUOUS-CTOR), exit 1 — NOT a silent accept.
cat > "$TMP/x674_amb.mdk" <<'EOF'
import x674b.{TB(..), mb}
import x674a.{TA(..), ma}
unA : TA -> Int
unA (Node x) = x
main = println (intToString (unA ma))
EOF
amb_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check --json "$TMP/x674_amb.mdk" 2>/dev/null)"
amb_code=$?
case "$amb_out" in
  *R-AMBIGUOUS-CTOR*) if [ "$amb_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   674a/ambiguous-ctor (cross-module dup ctor rejected, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL 674a/ambiguous-ctor (flagged but exit %d)\n' "$amb_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL 674a/ambiguous-ctor (no R-AMBIGUOUS-CTOR: [%s])\n' "$amb_out" ;;
esac
# 12b. build AGREEMENT: the ambiguous program must NOT build a (crashing) binary —
#      check and build agree that it is rejected, so the S0 miscompile is gone.
MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/x674_amb.mdk" -o "$TMP/x674_amb.bin" >/dev/null 2>&1
amb_bcode=$?
if [ "$amb_bcode" -ne 0 ] && [ ! -x "$TMP/x674_amb.bin" ]; then
  pass=$((pass+1)); printf 'ok   674b/no-crash-binary (ambiguous ctor never builds an executable)\n'
else
  fail=$((fail+1)); printf 'FAIL 674b/no-crash-binary (build exit %d, binary present=%s)\n' "$amb_bcode" "$([ -x "$TMP/x674_amb.bin" ] && echo yes || echo no)"
fi
# 12c. BARE-IMPORT VALIDITY: a bare `import x674b` (binds NO names — impls only) must
#      NOT inject its `Node` and reject a valid program that uses only x674a's `Node`.
#      check ACCEPTS and build AGREES, running to `111`.
cat > "$TMP/x674_bare.mdk" <<'EOF'
import x674a.{TA(..), ma}
import x674b
unA : TA -> Int
unA (Node x) = x
main = println (intToString (unA ma))
EOF
bare_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x674_bare.mdk" 2>/dev/null)"
bare_code=$?
case "$bare_out" in
  *"Type mismatch"*|*Ambiguous*) fail=$((fail+1)); printf 'FAIL 674c/bare-import-valid (bare import wrongly rejected: [%s])\n' "$bare_out" ;;
  *) if [ "$bare_code" -eq 0 ]; then
       if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/x674_bare.mdk" -o "$TMP/x674_bare.bin" >/dev/null 2>&1 && [ "$("$TMP/x674_bare.bin" 2>/dev/null)" = "111" ]; then
         pass=$((pass+1)); printf 'ok   674c/bare-import-valid (bare import stays impls-only; check+build run to 111)\n'
       else fail=$((fail+1)); printf 'FAIL 674c/bare-import-valid (check clean but build/run wrong)\n'; fi
     else fail=$((fail+1)); printf 'FAIL 674c/bare-import-valid (exit %d: [%s])\n' "$bare_code" "$bare_out"; fi ;;
esac
# 12d. USE-SITE firing: importing BOTH `Node`-exporting modules but USING NEITHER's
#      `Node` stays LEGAL (the ambiguity check fires only on a genuine ambiguous use).
cat > "$TMP/x674_unused.mdk" <<'EOF'
import x674b.{TB(..), mb}
import x674a.{TA(..), ma}
main = println "hi"
EOF
unused_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x674_unused.mdk" 2>/dev/null)"
unused_code=$?
case "$unused_out" in
  *Ambiguous*) fail=$((fail+1)); printf 'FAIL 674d/import-both-use-neither (false ambiguity on unused ctor: [%s])\n' "$unused_out" ;;
  *) if [ "$unused_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   674d/import-both-use-neither (unused dup ctor stays legal)\n'
     else fail=$((fail+1)); printf 'FAIL 674d/import-both-use-neither (exit %d: [%s])\n' "$unused_code" "$unused_out"; fi ;;
esac

# 13. #673 cross-module constrained-FUNCTION obligation on the located CHECK path.
#     Two guards, one root cause (instantiateVarTracked dropped a cross-module binding's
#     call obligation because per-module schemeObligationsRef has no entry for it):
#
#  13a. UNDER-rejection (#673 itself): a PRELUDE constrained fn (`println : Display a => …`)
#       applied to a 6-tuple (Display impls stop at arity 5) in an import-bearing program
#       MUST be rejected on `check` — it false-greened (exit 0, empty --json) while run/build
#       rejected via their separate dict net.  The fix reads core's OWN captured obligations
#       (coreSchemeObligationsRef) so the located path records the Display obligation.
cat > "$TMP/x673_reject.mdk" <<'EOF'
import helper.{double}
main = println (double 1, double 1, double 1, double 1, double 1, double 1)
EOF
x673r_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x673_reject.mdk" 2>/dev/null)"
x673r_code=$?
case "$x673r_out" in
  *"No impl of Display for (Int, Int, Int, Int, Int, Int)"*)
    if [ "$x673r_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   673a/prelude-fn-obligation (cross-module println Display obligation enforced)\n'
    else fail=$((fail+1)); printf 'FAIL 673a/prelude-fn-obligation (rejected but exit %d)\n' "$x673r_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL 673a/prelude-fn-obligation (cross-module obligation dropped: [%s])\n' "$x673r_out" ;;
esac
#  13b. OVER-rejection guard (the #673-rework regression): two modules export a same-named
#       `bar` — foo's is `Display a =>`-constrained, baz's is UNCONSTRAINED — and the entry
#       uses BAZ's `bar` on a no-`Display` type.  This is VALID; `check` MUST accept it.  A
#       source-BLIND name lookup misattributes foo's Display constraint to baz's `bar` and
#       falsely rejects `No impl of Display for NoD`; the source-exact lookup (qualConstraintFor
#       resolves `bar`→baz via currentImportDefinersRef) must not.  #739: the SAME source-blind
#       misattribution was ALSO present on the EMIT path (declaredConstraintSlots' bare-name
#       fallback + inferDictAtFound), so `run`/`build` OVER-REJECTED this valid program while
#       `check` (fixed by #673) accepted it.  It is now source-exact on the emit path too, so
#       ALL THREE verbs agree: check/run/build ACCEPT and the program prints `ok`.
cat > "$TMP/x673_foo.mdk" <<'EOF'
public export data FooT = FooT
export bar : Display a => a -> String
bar x = display x
EOF
cat > "$TMP/x673_baz.mdk" <<'EOF'
export bar : a -> a
bar x = x
EOF
cat > "$TMP/x673_collide.mdk" <<'EOF'
import x673_baz.{bar}
import x673_foo
public export data NoD = NoD
main =
  let _ = bar NoD
  println "ok"
EOF
x673c_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x673_collide.mdk" 2>/dev/null)"
x673c_code=$?
case "$x673c_out" in
  *"No impl"*) fail=$((fail+1)); printf 'FAIL 673b/samename-no-overreject (misattributed foreign constraint: [%s])\n' "$x673c_out" ;;
  *) if [ "$x673c_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   673b/samename-no-overreject (baz unconstrained bar not tagged with foo Display)\n'
     else fail=$((fail+1)); printf 'FAIL 673b/samename-no-overreject (exit %d: [%s])\n' "$x673c_code" "$x673c_out"; fi ;;
esac
#  13c. #739 EMIT-path over-rejection: the SAME same-name collision must be accepted by `run`
#       AND `build`, not just `check` — the emit path (declaredConstraintSlots/inferDictAtFound)
#       used to misattribute foo's `Display` to baz's unconstrained `bar` and reject with a
#       `type error` (exit 1) while `check` accepted (the dead-end circular message #673 warned
#       about).  Both must now exit 0 and PRINT `ok`.  Pre-fix this leg fails (run/build exit 1).
x739_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/x673_collide.mdk" 2>/dev/null)"
x739_run_code=$?
if [ "$x739_run_code" -eq 0 ] && [ "$x739_run" = "ok" ]; then
  pass=$((pass+1)); printf 'ok   739/samename-emit-run (run accepts + prints ok)\n'
else
  fail=$((fail+1)); printf 'FAIL 739/samename-emit-run (exit %d, out [%s])\n' "$x739_run_code" "$x739_run"
fi
MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/x673_collide.mdk" -o "$TMP/x739.out" >/dev/null 2>&1
x739_build_code=$?
x739_build_out="$([ -x "$TMP/x739.out" ] && "$TMP/x739.out" 2>/dev/null | head -1)"  # native rt auto-prints a trailing () line; take the first
if [ "$x739_build_code" -eq 0 ] && [ -x "$TMP/x739.out" ] && [ "$x739_build_out" = "ok" ]; then
  pass=$((pass+1)); printf 'ok   739/samename-emit-build (build succeeds + binary prints ok)\n'
else
  fail=$((fail+1)); printf 'FAIL 739/samename-emit-build (exit %d, binary=%s, out [%s])\n' "$x739_build_code" "$([ -x "$TMP/x739.out" ] && echo yes || echo no)" "$x739_build_out"
fi
#  13d. #739 fix follow-up — the UNDER-application hole (CI-caught regression of the first cut).
#       An ALIASED selective import of a CONSTRAINED fn (`import p.{f as g}`) used at a VALID
#       type MUST keep its dict — check/run/build all accept and print the value.  The first
#       #739 cut treated the alias local (`g`) as authoritative: it IS in currentImportDefinersRef
#       but `qualConstraintFor` missed (the qual table is keyed by the ORIGIN `f`, not the alias),
#       so declaredConstraintSlots returned ([],[]) and inferDictAtFound DROPPED the Display dict →
#       `no matching impl for dispatch` at run/build.  The alias→origin resolution (importOriginsOf
#       + currentImportOriginsRef) fixes it.  This is the same shape as hash_map.{set as hmSet}
#       (Hash/Eq dict) that diff_compiler_test's hash_negative_hash caught.
cat > "$TMP/aliascon_p.mdk" <<'EOF'
export f : Display a => a -> String
f x = display x
EOF
cat > "$TMP/aliascon.mdk" <<'EOF'
import aliascon_p.{f as g}
main = println (g 42)
EOF
ac_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/aliascon.mdk" 2>/dev/null)"
ac_run_code=$?
MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/aliascon.mdk" >/dev/null 2>&1
ac_check_code=$?
MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/aliascon.mdk" -o "$TMP/aliascon.out" >/dev/null 2>&1
ac_build_code=$?
ac_build_out="$([ -x "$TMP/aliascon.out" ] && "$TMP/aliascon.out" 2>/dev/null | head -1)"
if [ "$ac_check_code" -eq 0 ] && [ "$ac_run_code" -eq 0 ] && [ "$ac_run" = "42" ] && [ "$ac_build_code" -eq 0 ] && [ "$ac_build_out" = "42" ]; then
  pass=$((pass+1)); printf 'ok   739/aliased-constrained-import-keeps-dict (check/run/build all 42)\n'
else
  fail=$((fail+1)); printf 'FAIL 739/aliased-constrained-import-keeps-dict (check %d, run %d [%s], build %d [%s])\n' "$ac_check_code" "$ac_run_code" "$ac_run" "$ac_build_code" "$ac_build_out"
fi

#  13e. #749 CHECK-path UNDER-rejection (the #673 residual for USER modules — the INVERSE of
#       13b/13c).  A USER-module constrained fn (`x673_foo.bar : Display a => …`) applied to a
#       no-`Display` type (`NoD`) is genuinely UNSATISFIABLE; `run`/`build` reject it, but `check`
#       FALSE-GREENED (exit 0, empty --json) — #738 restored the located obligation only for the
#       PRELUDE/core flow (coreSchemeObligationsRef), while a user-module obligation flows through
#       the qual tables, which the check-diags path attributed under mid="" (never the real source
#       module), so qualConstraintFor always missed → declaredCrossModuleObls dropped it.  The fix
#       threads the REAL module id through checkModuleFullDiags → checkModuleFullImpl (source-exact,
#       exactly as the emit path does), so `check` now records + rejects the obligation.  All three
#       verbs must REJECT and check must carry a located `No impl of Display for NoD`.  The
#       source-exactness is what keeps 13b/13c (unconstrained same-name) ACCEPTED — no #739 revert.
cat > "$TMP/x749_use.mdk" <<'EOF'
import x673_foo.{bar}
public export data NoD = NoD
main =
  let _ = bar NoD
  println "ok"
EOF
x749_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x749_use.mdk" 2>/dev/null)"
x749_code=$?
case "$x749_out" in
  *"No impl of Display for NoD"*)
    if [ "$x749_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   749/usermodule-fn-obligation-check (user-module Display obligation enforced on check)\n'
    else fail=$((fail+1)); printf 'FAIL 749/usermodule-fn-obligation-check (located but exit %d)\n' "$x749_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL 749/usermodule-fn-obligation-check (obligation dropped on check: [%s])\n' "$x749_out" ;;
esac
# run/build must AGREE (both reject; no binary).
MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/x749_use.mdk" >/dev/null 2>&1
x749_run_code=$?
MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/x749_use.mdk" -o "$TMP/x749.out" >/dev/null 2>&1
x749_build_code=$?
if [ "$x749_run_code" -ne 0 ] && [ "$x749_build_code" -ne 0 ] && [ ! -x "$TMP/x749.out" ]; then
  pass=$((pass+1)); printf 'ok   749/usermodule-fn-obligation-agree (run+build reject too — check==run==build)\n'
else
  fail=$((fail+1)); printf 'FAIL 749/usermodule-fn-obligation-agree (run %d, build %d, binary=%s)\n' "$x749_run_code" "$x749_build_code" "$([ -x "$TMP/x749.out" ] && echo yes || echo no)"
fi
#  13f. #749 ALIASED variant: an aliased constrained user import (`import x673_foo.{bar as bz}`)
#       applied to the no-`Display` type must ALSO be rejected on check (alias→origin resolves via
#       importOriginsOf/currentImportOriginsRef, #750), while the aliased-on-VALID-type case (13d)
#       still accepts + routes its dict.  Guards that the fix rejects the invalid alias without
#       re-dropping the valid alias's dict.
cat > "$TMP/x749_alias.mdk" <<'EOF'
import x673_foo.{bar as bz}
public export data NoD = NoD
main =
  let _ = bz NoD
  println "ok"
EOF
x749a_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x749_alias.mdk" 2>/dev/null)"
x749a_code=$?
case "$x749a_out" in
  *"No impl of Display for NoD"*)
    if [ "$x749a_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   749/aliased-usermodule-fn-obligation-check (aliased user obligation enforced on check)\n'
    else fail=$((fail+1)); printf 'FAIL 749/aliased-usermodule-fn-obligation-check (located but exit %d)\n' "$x749a_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL 749/aliased-usermodule-fn-obligation-check (aliased obligation dropped: [%s])\n' "$x749a_out" ;;
esac

# ── 822: graded interface scope is per-DECLARATION, not per-NAME ──────────────
#
# Two UNRELATED modules each declare an interface named `GT`, both graded (#822,
# EFFECTS-SEMANTICS §6), with the Row in DIFFERENT slots.  A graded scope keyed by any
# bare String name — the typaram name, `GT`, or `GT@<slot>` — gives these two the SAME
# key, and such a table populated across module boundaries is last-write-wins with a
# SILENT loss.  That is one recurring root cause with four confirmed instances (eval
# frames' ctor collision; #1044 refindex; #1047 interface defaults; the first cut of
# #822), and relocating the key to a rarer namespace is not a fix — #1044 was created
# that way.  Both must therefore check clean, and in EITHER import order.
#
# ⚠️ THIS BELONGS HERE, not in test/check_module_fixtures/.  That harness diffs
# `check_modules_main`'s STDOUT scheme dump, and the graded scope is NOT OBSERVABLE
# there: an open row renders exactly like a type variable, a concrete index in a Row
# slot stays opaque, and a written row carries its own row-ness — so four fixtures
# written that way were green with the implementation arm deleted.  ACCEPTANCE is the
# only observable, and only this gate sees it.
cat > "$TMP/g822_ma.mdk" <<'EOF'
export interface GT f where
  gpinA : f e a -> (a -> <e> f e b) -> f e b
EOF
cat > "$TMP/g822_mb.mdk" <<'EOF'
export interface GT g where
  gpinB : g a e -> (a -> <e> g a e) -> g a e
EOF
cat > "$TMP/g822_ab.mdk" <<'EOF'
import g822_ma.{GT, gpinA}
import g822_mb.{gpinB}
main = println "ok"
EOF
cat > "$TMP/g822_ba.mdk" <<'EOF'
import g822_mb.{GT, gpinB}
import g822_ma.{gpinA}
main = println "ok"
EOF
for g822_order in ab ba; do
  g822_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/g822_$g822_order.mdk" 2>&1)"
  g822_code=$?
  if [ "$g822_code" -eq 0 ]; then
    pass=$((pass+1)); printf 'ok   822/same-named-graded-ifaces-%s (both keep their own slot kinds)\n' "$g822_order"
  else
    fail=$((fail+1)); printf 'FAIL 822/same-named-graded-ifaces-%s (exit %d: [%s])\n' "$g822_order" "$g822_code" "$g822_out"
  fi
done

# ── 822: a NON-graded interface must not inherit a graded namesake's kinds ────
#
# The discriminating shape, and the one that was actually broken (S1, review round 2):
# only ONE of the two interfaces need be graded.  `plainmod` is an ordinary, valid,
# self-contained library — `GT h` is `Type -> Type` and `Box` implements it.  Because
# `ifaceParamKindsRef` is copied into the data universe, which is NOT import-scoped, a
# graded interface of the same name ANYWHERE in the graph made `plainmod`'s impl fail
# T-IMPL-KIND-MISMATCH, and swapping the two unrelated import lines below flipped the
# verdict.  The front-overlay/first-match ordering did not protect it, because a
# non-graded interface used to register NO entry and so had no local entry to shadow
# with — see registerIfaceParamKindsGo.
#
# ⚠️ This is the pin the same-named-GRADED pair above could NOT provide: that pair
# passes on a tree with the old `<iface>@<slot>`-keyed lookup, so it only catches total
# absence of #822.  This one fails there.  Both orders, because the bug was order-dependent.
cat > "$TMP/g822_graded.mdk" <<'EOF'
export interface GT f where
  gm : f e a -> (a -> <e> f e b) -> f e b
EOF
cat > "$TMP/g822_plain.mdk" <<'EOF'
export interface GT h where
  plainm : h a -> h a
public export data Box a = Mk a
export impl GT Box where
  plainm x = x
EOF
cat > "$TMP/g822_mix_ab.mdk" <<'EOF'
import g822_graded.{gm}
import g822_plain.{Box, plainm}
main = println "ok"
EOF
cat > "$TMP/g822_mix_ba.mdk" <<'EOF'
import g822_plain.{Box, plainm}
import g822_graded.{gm}
main = println "ok"
EOF
for g822_order in ab ba; do
  g822m_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/g822_mix_$g822_order.mdk" 2>&1)"
  g822m_code=$?
  if [ "$g822m_code" -eq 0 ]; then
    pass=$((pass+1)); printf 'ok   822/nongraded-namesake-%s (ordinary interface keeps its own kinds)\n' "$g822_order"
  else
    fail=$((fail+1)); printf 'FAIL 822/nongraded-namesake-%s (valid program rejected, exit %d: [%s])\n' "$g822_order" "$g822m_code" "$g822m_out"
  fi
done

# ── #1111 A-2.10: TYPE-HEAD IDENTITY DECIDES ACCEPTANCE ──────────────────────
#
# The PERMANENT home for what `test/must_fail_fixtures/1208-…` and `1209-…` pinned
# while they were still bugs.  Those fixtures asserted the DEFECT (silent exit 0);
# they were deleted when A-2.10 drained them, and a drained must-fail leaves no
# regression test behind — so the two halves are re-asserted here as the thing that
# must now hold.  ACCEPTANCE is the only observable for both, which is what puts
# them in this gate rather than in `check_module_fixtures` (see the note at the 822
# block above for the same argument).
#
# ⚠️ BOTH MIRRORS ARE HERE ON PURPOSE, and the second is the one that catches the
# regression this change could actually cause.  Making a comparison STRICTER turns
# exit 0 into exit 1 — correct for two genuinely-distinct types, a REGRESSION for a
# valid program whose identity supply is incomplete.  `A-2.10/reject-*` is the first
# mirror; `A-2.10/accept-*` is the second, and it is not decoration: unit A-2.2b
# built this comparison on identity naively and the compiler REJECTED ITS OWN
# PRELUDE, because `stdlib/runtime.mdk`'s extern signatures carry no identity.
# `accept-extern-sourced` is that exact discriminator.
#
# The reject rows pin the DIAGNOSTIC CODE, not just a nonzero exit: a fixture typo
# would otherwise grade green on an unrelated rejection.
cat > "$TMP/a210_defa.mdk" <<'EOF'
public export data Tk = MkTkA Int
export takeTk : Tk -> Int
takeTk (MkTkA n) = n
export interface Wr a where
  wr : a -> Tk
export unTk : Tk -> Int
unTk (MkTkA n) = n
export mkTk : Int -> Tk
mkTk n = MkTkA n
EOF
# main declares its OWN `Tk`, with a DIFFERENT constructor name so the already-fixed
# R-AMBIGUOUS-CTOR path (#674/#732) cannot fire and mask this.
cat > "$TMP/a210_rej_fn.mdk" <<'EOF'
import a210_defa.{takeTk}
public export data Tk = MkTkB String
mk : Tk
mk = MkTkB "wrong"
main = println (takeTk mk)
EOF
# the #1209 half: the collision is an interface METHOD's declared RETURN type,
# reached through `methodIfaceParamsRef` rather than a plain function's parameter.
cat > "$TMP/a210_rej_method.mdk" <<'EOF'
import a210_defa.{Wr(..), wr, unTk}
public export data Tk = MkTkB String
export impl Wr Int where
  wr n = MkTkB "wrong"
main = println (unTk (wr 1))
EOF
for a210_case in fn method; do
  a210_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/a210_rej_$a210_case.mdk" 2>&1)"
  a210_code=$?
  a210_json="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check --json "$TMP/a210_rej_$a210_case.mdk" 2>/dev/null)"
  if [ "$a210_code" -ne 0 ] && printf '%s' "$a210_json" | grep -q 'T-TYPE-MISMATCH'; then
    pass=$((pass+1)); printf 'ok   A-2.10/reject-%s (two modules'"'"' same-named types no longer unify)\n' "$a210_case"
  else
    fail=$((fail+1)); printf 'FAIL A-2.10/reject-%s (exit %d, no T-TYPE-MISMATCH: [%s])\n' "$a210_case" "$a210_code" "$a210_out"
  fi
done
# The message would otherwise read `Type mismatch: Tk vs Tk` — both sides identical,
# which is true and unactionable.  Asserted here because a diagnostic nobody can act
# on trades an S0 for an S2 rather than fixing it, and no other gate looks at this
# text: the two must-fail fixtures that reached this shape are deleted.
a210_hint="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/a210_rej_fn.mdk" 2>&1)"
if printf '%s' "$a210_hint" | grep -q "share the name 'Tk'" \
  && printf '%s' "$a210_hint" | grep -q "a210_defa" \
  && printf '%s' "$a210_hint" | grep -q "a210_rej_fn"; then
  pass=$((pass+1)); printf 'ok   A-2.10/reject-names-both-modules\n'
else
  fail=$((fail+1)); printf 'FAIL A-2.10/reject-names-both-modules (identical-looking sides, no hint: [%s])\n' "$a210_hint"
fi
# ACCEPT mirror.  Every line names a head whose two sides acquire identity by
# DIFFERENT routes and must still be one type: an extern-sourced `Int` against the
# `OriginBuiltin` one the prelude's impls are written against; a user type whose
# NAME arrives across a RE-EXPORT hop while its VALUES arrive from the definer
# directly; and an exported ALIAS of that type.  The split import is the point —
# `Tk` and `TkAlias` come from `a210_relay`, `mkTk`/`takeTk` from `a210_defa` — so
# a re-export attributed to the RE-EXPORTER rather than to the definer makes the
# annotation and the value disagree and this row goes red.
cat > "$TMP/a210_relay.mdk" <<'EOF'
export import a210_defa.{Tk, mkTk}
export type TkAlias = Tk
EOF
cat > "$TMP/a210_accept.mdk" <<'EOF'
import a210_relay.{Tk, mkTk, TkAlias}
import a210_defa.{takeTk}
viaAlias : TkAlias -> Int
viaAlias t = takeTk t
externSourced : Bool
externSourced = stringLength "xy" < 2
fromExtern : Tk
fromExtern = mkTk (stringLength "hello")
main = println (takeTk fromExtern + viaAlias (mkTk 2))
EOF
a210_acc_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/a210_accept.mdk" 2>&1)"
a210_acc_code=$?
if [ "$a210_acc_code" -eq 0 ]; then
  pass=$((pass+1)); printf 'ok   A-2.10/accept-extern-sourced-and-reexported\n'
else
  fail=$((fail+1)); printf 'FAIL A-2.10/accept-extern-sourced-and-reexported (valid program rejected, exit %d: [%s])\n' "$a210_acc_code" "$a210_acc_out"
fi
a210_run_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/a210_accept.mdk" 2>&1)"
a210_run_code=$?
if [ "$a210_run_code" -eq 0 ] && [ "$a210_run_out" = "7" ]; then
  pass=$((pass+1)); printf 'ok   A-2.10/accept-runs-and-dispatches (7)\n'
else
  fail=$((fail+1)); printf 'FAIL A-2.10/accept-runs-and-dispatches (exit %d, got [%s], want 7)\n' "$a210_run_code" "$a210_run_out"
fi

# ── #1111 A-2.10: ONE PHYSICAL FILE MUST HAVE ONE IDENTITY ────────────────────
#
# THE ONLY NON-FLAT PROJECT IN ANY OF THESE CORPORA, AND THAT IS THE POINT.  Every
# directory under test/check_module_fixtures/ and test/eval_modules_fixtures/ is
# FLAT (`find <dir> -mindepth 2 -type d` is empty in all of them), so entry-dir ==
# project-root there and `entrySearchRoots` can only ever produce ONE search root.
# The defect below needs TWO, so no fixture in either corpus can express it and no
# amount of coverage there would have found it.  This gate synthesizes its projects,
# so it can — and it is the gate that already owns the other A-2.10 legs.
#
# The shape: a `medaka.toml` at the project root and the entry BELOW it, which is the
# layout `src/main.mdk` gives you.  `entrySearchRoots` then returns [src/, projroot],
# so `src/util.mdk` is reachable as BOTH `util` (from the entry, via src/) and
# `src.util` (from a non-sibling module, via the project root) — and the loader used
# to canonicalize ONLY imports resolving under a declared DEPENDENCY root, so the two
# spellings became two modIds for one file, i.e. two `OriginModule` ids for every
# declaration in it.
#
# ⚠️ THAT WAS A LIVE REGRESSION IN A-2.10's FIRST CUT, not a hypothetical: A-2.10
# makes comparisons READ those ids, so the entry's `Config` and `lib/thing.mdk`'s
# `Config` — the same declaration, in the same file — became two different types and
# an ordinary project went `exit 0` -> `exit 1` with `Type mismatch: Config vs Config`.
# The comparison was right; `canonicalModId` (compiler/driver/loader.mdk) was the
# wrong supply, and its own doc-comment had claimed the general fix for months while
# implementing only the dep-root half.
mkdir -p "$TMP/nest/src" "$TMP/nest/lib"
cat > "$TMP/nest/medaka.toml" <<'EOF'
name = "nest"
EOF
cat > "$TMP/nest/src/util.mdk" <<'EOF'
public export data Config = MkConfig Int

export interface Describe a where
  describe : a -> Int

export impl Describe Config where
  describe (MkConfig n) = n * 2

export unwrap : Config -> Int
unwrap (MkConfig n) = n
EOF
# NOT a sibling of the entry, so it must spell the import from the PROJECT root.
cat > "$TMP/nest/lib/thing.mdk" <<'EOF'
import src.util.{Config, MkConfig, unwrap}

export bump : Config -> Config
bump c = MkConfig (unwrap c + 1)
EOF
# The entry IS a sibling, so it spells the same file the other way.
cat > "$TMP/nest/src/main.mdk" <<'EOF'
import util.{Config, MkConfig, unwrap}
import lib.thing.{bump}

main = println (unwrap (bump (MkConfig 41)))
EOF
nest_chk="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/nest/src/main.mdk" 2>&1)"
nest_chk_code=$?
case "$nest_chk" in
  *"Type mismatch"*) fail=$((fail+1)); printf 'FAIL A-2.10/nested-project-check (one file, two modIds, two identities: [%s])\n' "$nest_chk" ;;
  *) if [ "$nest_chk_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   A-2.10/nested-project-check (src/ entry under a medaka.toml: one file, one identity)\n'
     else fail=$((fail+1)); printf 'FAIL A-2.10/nested-project-check (exit %d: [%s])\n' "$nest_chk_code" "$nest_chk"; fi ;;
esac
nest_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/nest/src/main.mdk" 2>&1)"
nest_run_code=$?
if [ "$nest_run_code" -eq 0 ] && [ "$nest_run" = "42" ]; then
  pass=$((pass+1)); printf 'ok   A-2.10/nested-project-run (42)\n'
else
  fail=$((fail+1)); printf 'FAIL A-2.10/nested-project-run (exit %d, got [%s], want 42)\n' "$nest_run_code" "$nest_run"
fi
# build AGREEMENT.  Not decoration: the canonical modId is also the per-module MANGLING
# PREFIX (`<mid>__<name>`, compiler/backend/private_mangle.mdk), so a canonicalization
# that check accepts and the emitter disagrees with is a run≠build miscompile rather
# than a diagnostic.  The binary must print 42 too.
if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/nest/src/main.mdk" -o "$TMP/nest.bin" >/dev/null 2>&1 && [ -x "$TMP/nest.bin" ]; then
  nest_bld="$("$TMP/nest.bin" 2>/dev/null | head -1)"
  if [ "$nest_bld" = "42" ]; then pass=$((pass+1)); printf 'ok   A-2.10/nested-project-build (mangling agrees: binary prints 42)\n'
  else fail=$((fail+1)); printf 'FAIL A-2.10/nested-project-build (got [%s], want 42)\n' "$nest_bld"; fi
else
  fail=$((fail+1)); printf 'FAIL A-2.10/nested-project-build (native build failed)\n'
fi
# The IMPL half of the same defect, and it is the one that was already broken BEFORE
# any comparison read an identity: two modIds for one file double-count its `export
# impl`, so `impl Describe Config` was reported as `Conflicting 'impl Describe'.
# Defined in util and src.util` — a false reject of a one-impl program, on `main`,
# today.  A-2.10 silently DRAINED that (the two copies stopped overlapping, because
# their heads had become different types) — a NOTHING -> SOMETHING transition that no
# pre-existing fixture could fail, which is exactly why it is pinned here.  It must
# now be accepted for the RIGHT reason: one module, one impl.  84 = describe (42).
cat > "$TMP/nest/src/impls.mdk" <<'EOF'
import util.{Config, MkConfig, Describe(..), describe}
import lib.thing.{bump}

main = println (describe (bump (MkConfig 41)))
EOF
nest_imp="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/nest/src/impls.mdk" 2>&1)"
nest_imp_code=$?
case "$nest_imp" in
  *Conflicting*) fail=$((fail+1)); printf 'FAIL A-2.10/nested-project-impl (one file counted twice: [%s])\n' "$nest_imp" ;;
  *) if [ "$nest_imp_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   A-2.10/nested-project-impl (a single export impl is not double-counted)\n'
     else fail=$((fail+1)); printf 'FAIL A-2.10/nested-project-impl (exit %d: [%s])\n' "$nest_imp_code" "$nest_imp"; fi ;;
esac
nest_imp_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/nest/src/impls.mdk" 2>&1)"
nest_imp_run_code=$?
if [ "$nest_imp_run_code" -eq 0 ] && [ "$nest_imp_run" = "84" ]; then
  pass=$((pass+1)); printf 'ok   A-2.10/nested-project-impl-run (84)\n'
else
  fail=$((fail+1)); printf 'FAIL A-2.10/nested-project-impl-run (exit %d, got [%s], want 84)\n' "$nest_imp_run_code" "$nest_imp_run"
fi
# 🚨 THE DISCRIMINATING NEGATIVE, and the accept legs above need it because NONE of
# them is one.  Measured on a binary carrying A-2.10 but NOT the loader fix: the
# `nested-project-impl` pair above stays GREEN there (two modIds gave the file's two
# copies DIFFERENT heads, so they stopped overlapping and the pre-existing false
# reject drained by accident), and so does an obvious "add a second impl in lib/"
# variant (both of ITS impls reach the shared type through the SAME spelling, so they
# conflict either way — that version was written, run, and discarded).
#
# What discriminates is a second impl reached through the OTHER SPELLING: `src/u.mdk`
# declares the type and the interface but NO impl; `src/other.mdk` (a sibling of the
# entry) writes `impl Desc Cfg` having imported it as `u`; `lib/t.mdk` (not a sibling)
# writes a SECOND `impl Desc Cfg` having imported the same file as `src.u`.  One
# modId ⇒ one `Cfg` ⇒ genuine overlap ⇒ REJECT naming both modules.
#
# ⚠️ ATTRIBUTION, MEASURED ON THREE BINARIES — and it is NARROWER than an earlier
# draft of this comment claimed.  That draft read the silent `2` as showing the
# two-modIds loader defect is "also an invalid program is silently miscompiled".
# It is not: on `main` (the loader defect alone, WITHOUT A-2.10) this same nest3
# program is CORRECTLY REJECTED — `Conflicting 'impl Desc'. Defined in other and
# lib.t`, exit 1, on both `check` and `run`.  Right answer, wrong reason (main's
# coherence compares heads by NAME, so it rejects two heads it also believes are
# two different types).  The silent exit-0 `2` — honest arithmetic for two live
# impls would be 1 + 2 = 3, so one call reaches the OTHER module's impl — appears
# ONLY on A-2.10-WITHOUT-the-loader-fix, an intermediate that never shipped.
#
# So: the pre-existing loader defect on `main` is a FALSE REJECT (S1, the
# `Config vs Config` / `nested-project-impl` legs).  The S0 was A-2.10's OWN, and
# the loader fix is what stops it shipping.  This leg pins a REJECT rather than
# merely a diagnostic because that intermediate is reachable by anyone who lands
# the comparison change without the supply change.
mkdir -p "$TMP/nest3/src" "$TMP/nest3/lib"
cat > "$TMP/nest3/medaka.toml" <<'EOF'
name = "nest3"
EOF
cat > "$TMP/nest3/src/u.mdk" <<'EOF'
public export data Cfg = MkCfg Int

export interface Desc a where
  desc : a -> Int
EOF
cat > "$TMP/nest3/src/other.mdk" <<'EOF'
import u.{Cfg, MkCfg, Desc(..), desc}

export impl Desc Cfg where
  desc (MkCfg n) = n

export viaSibling : Int
viaSibling = desc (MkCfg 1)
EOF
cat > "$TMP/nest3/lib/t.mdk" <<'EOF'
import src.u.{Cfg, MkCfg, Desc(..), desc}

export impl Desc Cfg where
  desc (MkCfg n) = n + 1

export viaProjRoot : Int
viaProjRoot = desc (MkCfg 1)
EOF
cat > "$TMP/nest3/src/m.mdk" <<'EOF'
import other.{viaSibling}
import lib.t.{viaProjRoot}

main = println (viaSibling + viaProjRoot)
EOF
n3_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/nest3/src/m.mdk" 2>&1)"
n3_code=$?
case "$n3_out" in
  *Conflicting*)
    case "$n3_out" in *other*) n3a=yes ;; *) n3a=no ;; esac
    case "$n3_out" in *lib.t*) n3b=yes ;; *) n3b=no ;; esac
    if [ "$n3_code" -eq 1 ] && [ "$n3a" = yes ] && [ "$n3b" = yes ]; then
      pass=$((pass+1)); printf 'ok   A-2.10/nested-project-real-conflict (two spellings are ONE module: cross-spelling overlap rejected)\n'
    else
      fail=$((fail+1)); printf 'FAIL A-2.10/nested-project-real-conflict (exit %d other=%s lib.t=%s: [%s])\n' "$n3_code" "$n3a" "$n3b" "$n3_out"
    fi ;;
  *) fail=$((fail+1)); printf 'FAIL A-2.10/nested-project-real-conflict (two impls for ONE type accepted — the file still has two modIds: exit %d [%s])\n' "$n3_code" "$n3_out" ;;
esac

# ── THE CANONICALIZATION MUST ROUND-TRIP (the loader fix's own S0) ────────────
#
# 🚨 THESE THREE LEGS EXIST BECAUSE THE FIX ABOVE INTRODUCED A WORSE BUG THAN THE
# ONE IT CLOSED, AND EVERY ACCEPT LEG ABOVE STAYED GREEN THROUGH IT.  `canonicalModId`
# mints an id with `moduleIdOfPath`, which is a LOSSY path→id map (`slashToDot`), and
# hands it straight back to `findModuleFile` — which reads it in a DIFFERENT namespace:
# declared dependency NAMES are consulted first, and every dot is a directory
# separator.  Measured on three binaries (`origin/main` 40756bea, PR-head-without-the-
# loader-hunk, PR head): main answers 42 to all three; the unguarded fix answers
# **99, 99, and `unknown module`**.  Two silent wrong FILES at exit 0 and one hard
# break, on programs that compiled correctly before.
#
# ⚠️ NOTHING ELSE IN THIS CORPUS CAN SEE THEM.  They are `nested-project-*`'s exact
# shape — an entry below its `medaka.toml`, so `entrySearchRoots` yields two roots —
# with ONE extra ingredient each, and the ingredient is what makes the minted id
# resolve somewhere else.  A leg that only asserts "the good layout still works"
# is a NOTHING → SOMETHING check by construction: before the fix no id was
# manufactured on this path at all, so no pre-existing fixture could fail.
#
# THE GUARD: accept the mint only if it re-resolves to the file it was derived
# from, else keep the raw spelling (`canonRoundTrips`, compiler/driver/loader.mdk).
# Delete the `canonRoundTrips` call and all three of these go red; the accept legs
# above do not.

# (a) DEP-NAME CAPTURE — the nastiest, because it is a silent wrong FILE at exit 0.
#     `src` is both the entry's own directory AND a declared dependency name.  The
#     import `util` resolves next to the entry, canonicalizes to `src.util`, and
#     re-resolution hits `resolveDepFile` first — so the DEP's `other/util.mdk` is
#     loaded in place of the sibling the programmer wrote.  42 -> 99, exit 0.
mkdir -p "$TMP/rtdep/src" "$TMP/rtdep/other"
cat > "$TMP/rtdep/medaka.toml" <<'EOF'
name = "rtdep"

[dependencies]
src = "./other"
EOF
cat > "$TMP/rtdep/src/util.mdk" <<'EOF'
export answer : Int
answer = 42
EOF
cat > "$TMP/rtdep/other/util.mdk" <<'EOF'
export answer : Int
answer = 99
EOF
cat > "$TMP/rtdep/src/main.mdk" <<'EOF'
import util.{answer}

main = println answer
EOF
rt_a="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/rtdep/src/main.mdk" 2>&1)"
rt_a_code=$?
if [ "$rt_a_code" -eq 0 ] && [ "$rt_a" = "42" ]; then
  pass=$((pass+1)); printf 'ok   A-2.10/canon-roundtrip-depname (the sibling util.mdk is loaded, not the same-named dep)\n'
else
  fail=$((fail+1)); printf 'FAIL A-2.10/canon-roundtrip-depname (SILENT WRONG FILE: exit %d, got [%s], want 42)\n' "$rt_a_code" "$rt_a"
fi

# (b) DOTTED DIRECTORY, SHADOWED — silent wrong file at exit 0.  The entry lives in
#     `a.b/`, so `helper` mints `a.b.helper`, which re-reads as `a/b/helper.mdk`.
mkdir -p "$TMP/rtdot/a.b" "$TMP/rtdot/a/b"
cat > "$TMP/rtdot/medaka.toml" <<'EOF'
name = "rtdot"
EOF
cat > "$TMP/rtdot/a.b/helper.mdk" <<'EOF'
export answer : Int
answer = 42
EOF
cat > "$TMP/rtdot/a/b/helper.mdk" <<'EOF'
export answer : Int
answer = 99
EOF
cat > "$TMP/rtdot/a.b/main.mdk" <<'EOF'
import helper.{answer}

main = println answer
EOF
rt_b="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/rtdot/a.b/main.mdk" 2>&1)"
rt_b_code=$?
if [ "$rt_b_code" -eq 0 ] && [ "$rt_b" = "42" ]; then
  pass=$((pass+1)); printf 'ok   A-2.10/canon-roundtrip-dotted-dir (a `.` in a DIRECTORY name is not a separator)\n'
else
  fail=$((fail+1)); printf 'FAIL A-2.10/canon-roundtrip-dotted-dir (SILENT WRONG FILE: exit %d, got [%s], want 42)\n' "$rt_b_code" "$rt_b"
fi

# (c) DOTTED DIRECTORY, UNSHADOWED — the same mint with no file to land on, so it is
#     a HARD BREAK (`unknown module: a.b.helper`) rather than a wrong answer.  Kept
#     as its own leg: (b) and (c) differ only in whether a decoy exists, and a fix
#     that merely reordered the roots would split them.
mkdir -p "$TMP/rtdot2/a.b"
cat > "$TMP/rtdot2/medaka.toml" <<'EOF'
name = "rtdot2"
EOF
cat > "$TMP/rtdot2/a.b/helper.mdk" <<'EOF'
export answer : Int
answer = 42
EOF
cat > "$TMP/rtdot2/a.b/main.mdk" <<'EOF'
import helper.{answer}

main = println answer
EOF
rt_c="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/rtdot2/a.b/main.mdk" 2>&1)"
rt_c_code=$?
if [ "$rt_c_code" -eq 0 ] && [ "$rt_c" = "42" ]; then
  pass=$((pass+1)); printf 'ok   A-2.10/canon-roundtrip-dotted-dir-nofallback (an unresolvable mint is never emitted)\n'
else
  fail=$((fail+1)); printf 'FAIL A-2.10/canon-roundtrip-dotted-dir-nofallback (exit %d, got [%s], want 42)\n' "$rt_c_code" "$rt_c"
fi

# ── #1111 A-2.10: TWO MODULES' SAME-NAMED TYPES MAY EACH CARRY THEIR OWN IMPL ──
#
# The NEW ACCEPTANCE this unit ships, and it had no fixture.  `impl Shower Twain` in
# two unrelated modules used to OVERLAP — coherence compared the two heads by NAME —
# so a program importing both was rejected with `Conflicting 'impl Shower'. Defined
# in a210_sha and a210_shz`.  They are different types, so that was always a false
# reject; `cohGoR`/`cohStep`/`cohEqR` reading identity is what ends it.
#
# ⚠️ THE PIN IS THE DISPATCH, NOT THE EXIT CODE.  Accepting two overlapping-by-name
# impls is only correct if each receiver reaches ITS OWN — an accept that then
# dispatched both calls to one impl would be a silent wrong answer, i.e. strictly
# worse than the false reject it replaced.  So both values are printed and both are
# graded, on `run` AND on the built binary (dispatch is OUTLINED in the emitter, so
# the two engines can disagree here and only a build leg sees it).
cat > "$TMP/a210_sha.mdk" <<'EOF'
public export data Twain = MkA Int
export interface Shower a where
  shows : a -> Int
export impl Shower Twain where
  shows (MkA n) = n
export mkA : Twain
mkA = MkA 1
EOF
cat > "$TMP/a210_shz.mdk" <<'EOF'
import a210_sha.{Shower(..), shows}
public export data Twain = MkZ Int
export impl Shower Twain where
  shows (MkZ n) = n
export mkZ : Twain
mkZ = MkZ 100
EOF
cat > "$TMP/a210_shmain.mdk" <<'EOF'
import a210_sha.{Shower(..), shows, mkA}
import a210_shz.{mkZ}
main =
  println (shows mkA)
  println (shows mkZ)
EOF
sh_chk="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/a210_shmain.mdk" 2>&1)"
sh_chk_code=$?
case "$sh_chk" in
  *Conflicting*) fail=$((fail+1)); printf 'FAIL A-2.10/samename-impls-check (false overlap on two DIFFERENT types: [%s])\n' "$sh_chk" ;;
  *) if [ "$sh_chk_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   A-2.10/samename-impls-check (same-named types no longer overlap)\n'
     else fail=$((fail+1)); printf 'FAIL A-2.10/samename-impls-check (exit %d: [%s])\n' "$sh_chk_code" "$sh_chk"; fi ;;
esac
sh_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/a210_shmain.mdk" 2>/dev/null | tr '\n' ',')"
if [ "$sh_run" = "1,100," ]; then
  pass=$((pass+1)); printf 'ok   A-2.10/samename-impls-run (each receiver reaches ITS OWN impl: 1,100)\n'
else
  fail=$((fail+1)); printf 'FAIL A-2.10/samename-impls-run (got [%s], want [1,100,])\n' "$sh_run"
fi
if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/a210_shmain.mdk" -o "$TMP/a210_sh.bin" >/dev/null 2>&1 && [ -x "$TMP/a210_sh.bin" ]; then
  sh_bld="$("$TMP/a210_sh.bin" 2>/dev/null | head -2 | tr '\n' ',')"
  if [ "$sh_bld" = "1,100," ]; then pass=$((pass+1)); printf 'ok   A-2.10/samename-impls-build (native dispatch agrees: 1,100)\n'
  else fail=$((fail+1)); printf 'FAIL A-2.10/samename-impls-build (got [%s], want [1,100,])\n' "$sh_bld"; fi
else
  fail=$((fail+1)); printf 'FAIL A-2.10/samename-impls-build (native build failed)\n'
fi

# ── #1277, DRAINED BY A-2.10 — re-pointed here rather than deleted ────────────
#
# `test/must_fail_fixtures/1277-xmod-head-spelling-collision-across-ifaces/` pinned
# this as a REPRODUCING S0 (it shipped with A-2.2b, #1274, which deliberately did
# NOT touch the comparisons).  A-2.10 drains it, and a drained must-fail leaves no
# regression test behind — so its assertion moves here, exactly as the #1208/#1209
# legs above did.
#
# The shape is NOT a duplicate of `A-2.10/samename-impls-*`: there the two same-named
# types carry impls of the SAME interface, so the question is only which impl.  Here
# the two interfaces are DIFFERENT (`Fa`, `Fb`) and merely share a method NAME, so a
# head-spelling collision reached the wrong impl AND the wrong interface — `B.ff
# (B.mkB 0)`, whose receiver is `b.H` and whose only `Fb` impl answers 2, printed 1.
# Measured before: `(1, 1)` at exit 0 on eval AND native, zero diagnostics.  Both
# engines are graded because both were wrong.
# ⚠️ These two legs (x1277_run below, x1277_bld further down) are stage A-3's
# E1 tripwire (#1112) — the acceptance case a whole-graph `IE` must keep
# passing. Nothing else in the tree names that role for them.
cat > "$TMP/x1277_a.mdk" <<'EOF'
public export data H = MkA Int

export interface Fa x where
  ff : x -> Int

impl Fa H where
  ff _ = 1

export mkA : Int -> H
mkA n = MkA n
EOF
cat > "$TMP/x1277_b.mdk" <<'EOF'
public export data H = MkB Int

export interface Fb x where
  ff : x -> Int

impl Fb H where
  ff _ = 2

export mkB : Int -> H
mkB n = MkB n
EOF
cat > "$TMP/x1277_main.mdk" <<'EOF'
import x1277_a as A
import x1277_b as B

main =
  let x = A.ff (A.mkA 0)
  let y = B.ff (B.mkB 0)
  println (x, y)
EOF
x1277_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/x1277_main.mdk" 2>&1)"
x1277_run_code=$?
if [ "$x1277_run_code" -eq 0 ] && [ "$x1277_run" = "(1, 2)" ]; then
  pass=$((pass+1)); printf 'ok   A-2.10/1277-xmod-head-spelling-run (right impl AND right interface: (1, 2))\n'
else
  fail=$((fail+1)); printf 'FAIL A-2.10/1277-xmod-head-spelling-run (exit %d, got [%s], want (1, 2))\n' "$x1277_run_code" "$x1277_run"
fi
if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/x1277_main.mdk" -o "$TMP/x1277.bin" >/dev/null 2>&1 && [ -x "$TMP/x1277.bin" ]; then
  x1277_bld="$("$TMP/x1277.bin" 2>/dev/null | head -1)"
  if [ "$x1277_bld" = "(1, 2)" ]; then pass=$((pass+1)); printf 'ok   A-2.10/1277-xmod-head-spelling-build (native agrees: (1, 2))\n'
  else fail=$((fail+1)); printf 'FAIL A-2.10/1277-xmod-head-spelling-build (got [%s], want (1, 2))\n' "$x1277_bld"; fi
else
  fail=$((fail+1)); printf 'FAIL A-2.10/1277-xmod-head-spelling-build (native build failed)\n'
fi

# ── #1280: EXTERN SIGNATURES CARRY IDENTITY (the SUPPLY half of Stage A-2) ────
#
# `externSchemes` (compiler/types/typecheck.mdk) used to turn each `DExtern`'s
# declared `Ty` into a `Scheme` OUTSIDE `stampTyOrigins`' walk, so every `Mono`
# flowing out of an extern's declared type reached its consumers `OriginUnresolved`
# on BOTH driver arms.  It now stamps under `externTyOriginScope`
# (compiler/frontend/resolve.mdk).
#
# 🔬 WHAT WAS MEASURED, first-hand, on this tree, rather than inferred.  The
# goal-side dispatch head for a user-declared interface at `Float`, dumped by a
# temporary probe in `headTyconMono` and rendered through `regKeyRender`:
#
#                                     before            after
#   probeMeth x  (x : Float)      builtin0:5:Float   builtin0:5:Float
#   probeMeth (intToFloat 1)      bare0:5:Float      builtin0:5:Float
#
# — identical on the flat arm and the module arm.  A second probe, walking every
# extern signature AFTER the stamping walk, reported ZERO surviving
# `OriginUnresolved` heads on all four user-facing driver verbs (flat check, module
# check, module run, flat run); with the stamping stubbed to `omEmpty` it reported
# hundreds, so the probe was able to fail.  Neither probe is in the tree; the legs
# below are the observable consequences that are.
#
# ⚠️ SUPPLY IS TOTAL ON THE USER-FACING ARMS ONLY, and that is stated because it is
# a real bound on the claim, not a caveat about it.  The prelude-FLATTENED internal
# passes (`elaborateDict`, `discoverPromoted`, `discoverPromotedJoint`,
# `checkMatchToLines`) have no prelude boundary to attribute `Option`/`Ordering`/
# `Result` to, so they pass `externTyOriginScope []` and those three heads stay
# absent there.  That is symmetric rather than partial: on those paths the
# prelude's OWN declarations are unstamped too (`checkProgramSeededSplit` with
# `coreProg0 = []`), so both sides of every comparison are equally identity-less.
#
# ── leg 1: the FEATURE.  The permanent home for test/must_fail_fixtures/1279-… ──
# That fixture pinned the bug (check exits 0 on a type-unsound program); it drains
# when this lands, and a drained must-fail leaves no regression test behind — the
# same argument the A-2.10 block above makes for 1208/1209.  An extern's `Option`
# with no identity sat BETWEEN `Option@core` and a second module's own `Option` and
# let unification link them, because `sameTyConHead` is absence-makes-no-claim and
# unification LINKS.  With the extern head supplied there is nothing to bridge
# through, and A-2.10's comparison refuses the pair with NO edit to the comparison.
cat > "$TMP/x1280_evil.mdk" <<'EOF'
public export data Ordering = MyLt | MyEq | MyGt

export interface Foldable f where
  myfold : f a -> Int

public export data Option a = MyJust a

export unwrapEvil : Option Int -> Int
unwrapEvil (MyJust n) = n + 1000
EOF
# `Ordering` + `Foldable` together make `programIsCore` (a purely SYNTACTIC
# self-test, compiler/frontend/resolve.mdk) answer True for x1280_evil, which
# collapses its `typeSeed` and is what lets it declare a second `Option` at all.
# That predicate is #1279's OTHER fix territory and is deliberately NOT touched
# here — this leg asserts the supply half closes the hole on its own.
cat > "$TMP/x1280_bridge.mdk" <<'EOF'
import x1280_evil.{unwrapEvil}

mid = stringIndexOf "zz" "a"

usesCore : Bool
usesCore = isSome mid

main =
  println usesCore
  println (unwrapEvil mid)
EOF
x1280_rej="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x1280_bridge.mdk" 2>&1)"
x1280_rej_code=$?
x1280_rej_json="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check --json "$TMP/x1280_bridge.mdk" 2>/dev/null)"
if [ "$x1280_rej_code" -ne 0 ] && printf '%s' "$x1280_rej_json" | grep -q 'T-TYPE-MISMATCH'; then
  pass=$((pass+1)); printf 'ok   1280/reject-absent-origin-bridge (extern Option no longer bridges two identities)\n'
else
  fail=$((fail+1)); printf 'FAIL 1280/reject-absent-origin-bridge (exit %d, no T-TYPE-MISMATCH: [%s])\n' "$x1280_rej_code" "$x1280_rej"
fi
# The message must name BOTH modules.  Same argument as A-2.10/reject-names-both-
# modules: `Type mismatch: Option vs Option` is true and unactionable, and no other
# gate reads this text once the must-fail fixture is deleted.
if printf '%s' "$x1280_rej" | grep -q "share the name 'Option'" \
  && printf '%s' "$x1280_rej" | grep -q "x1280_evil" \
  && printf '%s' "$x1280_rej" | grep -q "core"; then
  pass=$((pass+1)); printf 'ok   1280/reject-names-both-modules\n'
else
  fail=$((fail+1)); printf 'FAIL 1280/reject-names-both-modules (no actionable hint: [%s])\n' "$x1280_rej"
fi
#
# ── leg 2: the BYSTANDER.  "feature + UNRELATED code still behaves" ────────────
# AGENTS.md requires this shape of any change that alters what a PROGRAM-WIDE
# comparison answers, and it is the one that catches this change's real failure
# mode: supplying an identity can only ever turn an ACCEPT into a REJECT, so the
# risk is a valid program refused, not an invalid one admitted.  A-2.2b shipped
# exactly that regression (the compiler rejected its own prelude) and the uniform
# alternative measured while scoping this unit does too — stamping the whole extern
# population `OriginBuiltin` makes plain `isSome (stringIndexOf "z" "abc")` fail
# with `Option vs Option — one comes from module 'core', the other from the language
# itself`.  Hence: every binding below reaches a head OUT OF AN EXTERN and hands it
# to a prelude or user consumer whose head acquired identity by a DIFFERENT route.
#
# The graph also CONTAINS a same-name collision — `x1280_defs` and `x1280_other`
# both declare a type `Twin` — and the entry names NEITHER.  Only their unrelated
# functions are imported, so both `Twin`s are registered into the cross-module
# universe while nothing below mentions the name.
#
# ⚠️ EXPECTED VALUES ARE DERIVED FROM THE DECLARED SEMANTICS, NOT CAPTURED, per
# AGENTS.md's "a captured golden records what the engine DID".  Each term, from
# stdlib/runtime.mdk's signatures and stdlib/core.mdk's definitions:
#   charFromCode 65        = Some 'A'   (ASCII 65)   -> fromOption -> charCode = 65
#   stringToFloat "2.5"    = Some 2.5   -> +7.5 = 10.0 exactly (both are exact
#                                          binary fractions) -> floatToInt = 10
#   stringCompare "a" "b"  = Lt         ('a'=97 < 'b'=98)     -> 100
#   arrayLength (stringToChars "abcd")  = 4
#   floatToInt (sqrt (intToFloat 16))   = floatToInt 4.0      = 4
#   unTwinA (twinA (stringLength "xyz"))                      = 3
#   otherLen "ab"          = stringLength "ab"                = 2
#   total = 65 + 10 + 100 + 4 + 4 + 3 + 2                     = 188
cat > "$TMP/x1280_defs.mdk" <<'EOF'
public export data Twin = MkTwinA Int

export twinA : Int -> Twin
twinA n = MkTwinA n

export unTwinA : Twin -> Int
unTwinA (MkTwinA n) = n
EOF
cat > "$TMP/x1280_other.mdk" <<'EOF'
public export data Twin = MkTwinB String

export otherLen : String -> Int
otherLen s = stringLength s
EOF
cat > "$TMP/x1280_bystander.mdk" <<'EOF'
import x1280_defs.{twinA, unTwinA} -- ONLY the functions; never defs' Twin
import x1280_other.{otherLen}      -- ONLY the function; never other's Twin

viaOptionChar : Int
viaOptionChar = charCode (fromOption 'z' (charFromCode 65))

viaOptionFloat : Int
viaOptionFloat = floatToInt (fromOption 0.0 (stringToFloat "2.5") + 7.5)

viaOrdering : Int
viaOrdering = match stringCompare "a" "b"
  Lt => 100
  Eq => 0
  Gt => 0

viaArray : Int
viaArray = arrayLength (stringToChars "abcd")

viaFloat : Int
viaFloat = floatToInt (sqrt (intToFloat 16))

viaUserType : Int
viaUserType = unTwinA (twinA (stringLength "xyz"))

main =
  println (viaOptionChar + viaOptionFloat + viaOrdering + viaArray + viaFloat + viaUserType + otherLen "ab")
EOF
x1280_acc="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/x1280_bystander.mdk" 2>&1)"
x1280_acc_code=$?
if [ "$x1280_acc_code" -eq 0 ]; then
  pass=$((pass+1)); printf 'ok   1280/bystander-check (extern-sourced heads still meet their consumers)\n'
else
  fail=$((fail+1)); printf 'FAIL 1280/bystander-check (valid program rejected, exit %d: [%s])\n' "$x1280_acc_code" "$x1280_acc"
fi
x1280_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/x1280_bystander.mdk" 2>&1)"
x1280_run_code=$?
if [ "$x1280_run_code" -eq 0 ] && [ "$x1280_run" = "188" ]; then
  pass=$((pass+1)); printf 'ok   1280/bystander-run (188)\n'
else
  fail=$((fail+1)); printf 'FAIL 1280/bystander-run (exit %d, got [%s], want 188)\n' "$x1280_run_code" "$x1280_run"
fi
# The BUILD leg is not decoration here: the stamping site on the emit arm is
# `elaborateModules`, the seam `run` and the separate `medaka_emitter` process
# share, so an extern head stamped on one and not the other is a run != build
# divergence rather than a diagnostic.
if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/x1280_bystander.mdk" -o "$TMP/x1280.bin" >/dev/null 2>&1 && [ -x "$TMP/x1280.bin" ]; then
  x1280_bld="$("$TMP/x1280.bin" 2>/dev/null | head -1)"
  if [ "$x1280_bld" = "188" ]; then pass=$((pass+1)); printf 'ok   1280/bystander-build (native agrees: 188)\n'
  else fail=$((fail+1)); printf 'FAIL 1280/bystander-build (got [%s], want 188)\n' "$x1280_bld"; fi
else
  fail=$((fail+1)); printf 'FAIL 1280/bystander-build (native build failed)\n'
fi

# 20. #1112 A-3.4 PR2 — THE `IE` PROJECTION IS FILTERED AT THE *READING MODULE'S*
#     ORDINAL.  This is the one property the flip made live and that nothing in the
#     tree covered before it, and the reason is structural: through A-3.4 PR1 the
#     `IE` registry had ZERO readers, so every existing fixture graded the INERT
#     case.  A fixture built from coverage would therefore have found nothing to
#     add; this one is built from the spec instead (`compiler/TYPECHECK-TARGET-
#     ARCHITECTURE.md` §9.2/§9.5, `docs/spec/DICT-SEMANTICS.md` §8 I5).
#
#     `checkBodyImpl`'s Module arm now builds its obligation universe as
#     `ieUniverseAt (declEnvsOrdOf mid envs) envs.deImpls` — a whole-graph table
#     projected down to the ordinal PREFIX of the module being checked.  Two ways
#     to get that ordinal wrong, and the two legs below are chosen to catch one
#     each, so neither can pass for the other's reason:
#
#       (a) TOO SMALL (the #1508 shape: every user module arrives at ordinal 0)
#           — an impl in an imported, topologically EARLIER module goes missing
#           and a valid program is rejected.  Leg `earlier-visible` fails.
#       (b) TOO LARGE (projecting the whole graph, i.e. doing A-3.6 early by
#           accident) — an impl in a topologically LATER module the goal's module
#           never imports becomes a candidate, and a program today's compiler
#           rejects is SILENTLY ACCEPTED.  Leg `later-invisible` fails.
#
#     The two legs are the SAME three modules with the SAME text; only the entry's
#     two `import` lines are swapped, which is what moves `amod` across `midmod` in
#     the loader's dependency-first order.  Holding everything else constant is the
#     point — `midmod` imports only `zsizer` in both arms and never imports `amod`
#     in either, so an import-SCOPE explanation is excluded and the deciding
#     variable is the ordinal.  (Same construction as #1112's A/A2 measurement.)
#
# ✅ A-3.6 LANDED (2026-08-13) AND FLIPPED THIS LEG, EXACTLY AS LICENSED BELOW.
#     `later-invisible` is now `later-visible`: both arms accept, both run `5`, and
#     the leg asserts they AGREE.  That agreement is I5's own rule — import scoping
#     filters NAMES, never instances — so the arms disagreeing WAS the defect.
#     ⚠️ The precondition the note below attaches was CHECKED, not assumed.  There is
#     exactly ONE `interface Sizer` here (declared in `zsizer`, imported by both
#     modules), so no same-spelled collision exists and this accept cannot be
#     #1438's silent accept.  And it is a REAL accept, not a candidacy-only one:
#     `check`, `run` AND the built binary were each measured at `5` before this leg
#     was rewritten.  `impl Sizer Int` carries no `requires`, so no dictionary needs
#     routing and the direct channel answers.  A CONDITIONAL impl in the same
#     position still rejects, loudly, with `T-REQUIRES-UNROUTED` — see
#     `must_fail_fixtures/1564-*`.
#     📌 This gate's own instruction is what made the flip checkable rather than a
#     judgement call, so the historical note is kept verbatim below.  It also caught
#     a real error: this red was twice reported as "pre-existing, not ours" before
#     anyone read these lines.  It is ours, and it is correct.
#
# 🚨 READ BEFORE "FIXING" THE `later-invisible` LEG.  It pins a TRANSITIONAL
#     answer, not a correct one.  `DICT-SEMANTICS.md` §8 I5 says instance candidacy
#     is GRAPH-GLOBAL — import scoping filters NAMES, never instances — so the
#     spec-correct verdict for BOTH arms is the same one, and the fact that these
#     two arms disagree at all is a live S1 filed as issue 1564 (§11's I5 row is
#     graded 🔴 PARTIAL for exactly this).  This gate does not endorse that; it
#     pins that A-3.4 PR2 did not MOVE it.  MEASURED both arms on the base binary
#     (`main` @ 7c562b14) and on the flipped one: identical verdicts, identical
#     diagnostics.  The unit licensed to change this leg is **A-3.6** (issue 1558),
#     the candidacy flip, which deletes `declEnvVisibleAt`'s body — and per #1482's
#     measurement it may only do so once obligation goals stop keying by bare
#     spelling, or the accept arm generalizes into #1438's silent accept.  If you
#     are here because this leg went red, the question is not "what wording do I
#     update" but "am I A-3.6, and did I bring its fixtures".
cat > "$TMP/zsizer.mdk" <<'EOF'
export interface Sizer x where
  size : x -> Int
EOF
cat > "$TMP/midmod.mdk" <<'EOF'
import zsizer.{Sizer, size}

export goalVal : Int
goalVal = size 5
EOF
cat > "$TMP/amod.mdk" <<'EOF'
import zsizer.{Sizer, size}

impl Sizer Int where
  size n = n
EOF
# (a) `amod` first ⇒ order zsizer, amod, midmod, main ⇒ the impl's ordinal is
#     BELOW midmod's ⇒ visible ⇒ accept, and `run` yields the impl's own answer.
cat > "$TMP/ord_earlier.mdk" <<'EOF'
import amod
import midmod.{goalVal}

main = println goalVal
EOF
# (b) `midmod` first ⇒ order zsizer, midmod, amod, main ⇒ the impl's ordinal is
#     ABOVE midmod's ⇒ filtered out ⇒ reject, located in midmod.
cat > "$TMP/ord_later.mdk" <<'EOF'
import midmod.{goalVal}
import amod

main = println goalVal
EOF
ord_e_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/ord_earlier.mdk" 2>&1)"
ord_e_code=$?
if [ "$ord_e_code" -eq 0 ]; then
  pass=$((pass+1)); printf 'ok   1112-A34/earlier-visible (impl at a lower ordinal reaches the goal)\n'
else
  fail=$((fail+1)); printf 'FAIL 1112-A34/earlier-visible (ordinal too small — valid program rejected, exit %d: [%s])\n' "$ord_e_code" "$ord_e_out"
fi
ord_e_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/ord_earlier.mdk" 2>&1)"
ord_e_run_code=$?
if [ "$ord_e_run_code" -eq 0 ] && [ "$ord_e_run" = "5" ]; then
  pass=$((pass+1)); printf 'ok   1112-A34/earlier-visible-run (5)\n'
else
  fail=$((fail+1)); printf 'FAIL 1112-A34/earlier-visible-run (exit %d, got [%s], want 5)\n' "$ord_e_run_code" "$ord_e_run"
fi
ord_l_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/ord_later.mdk" 2>&1)"
ord_l_code=$?
if [ "$ord_l_code" -eq 0 ]; then
  pass=$((pass+1)); printf 'ok   1112-A34/later-visible (A-3.6: candidacy is graph-global, the ordinal no longer decides)\n'
else
  fail=$((fail+1)); printf 'FAIL 1112-A34/later-visible (a topologically LATER impl was filtered out — A-3.6 regressed, exit %d: [%s])\n' "$ord_l_code" "$ord_l_out"
fi
# An exit-0 assertion ALONE would not be enough here, and that is the whole lesson
# of the repair round: A-3.6 widened CANDIDACY, and where the evidence channel does
# not follow, a program accepts and then SEGFAULTS (SA-1, found one type signature
# away from a fix that had been verified against its own repro).  So grade the
# VALUE, on the engine, and require the two import orders to AGREE — agreement is
# the property I5 actually asserts, and it is what an exit code cannot see.
ord_l_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/ord_later.mdk" 2>&1)"
ord_l_run_code=$?
if [ "$ord_l_run_code" -eq 0 ] && [ "$ord_l_run" = "5" ] && [ "$ord_l_run" = "$ord_e_run" ]; then
  pass=$((pass+1)); printf 'ok   1112-A34/later-visible-run (5, and BOTH import orders agree)\n'
else
  fail=$((fail+1)); printf 'FAIL 1112-A34/later-visible-run (exit %d, got [%s], want 5 and equal to the earlier arm [%s])\n' "$ord_l_run_code" "$ord_l_run" "$ord_e_run"
fi

# 9. #1512 (ARCH A-3.2b residual, slice 1/3): THE CROSS-MODULE TYPE-ALIAS TABLE IS
#    STAGE K.  `crossRun.universeAliasTable` — the per-module-grown accumulator
#    `loadDataUniverse`/`storeDataUniverse` marshalled — is retired; the per-run
#    `aliasTableRef` is now seeded by `aliasUniverseAt cur declEnvsRef.deData.deAliases`,
#    i.e. the public aliases of every module at a STRICTLY LOWER ordinal.
#
#    (a) alias-visible.  An imported `export type Sec = Int` must still EXPAND in the
#    importer: `use : Sec -> Int` renders as `Int -> Int` and `s + 1` typechecks.
#
#    ⚠️ FAIL-CAPABILITY, DERIVED RATHER THAN ASSERTED — and an earlier draft of this
#    comment named a mechanism that does NOT occur in this leg's own configuration
#    (`No impl of Num for Sec`; cross-module, wrapping the alias in an attribute
#    instead gives a resolve-stage `has no exported name`, and the `No impl` shape
#    only appears single-module).  The real derivation: force `aliasUniverseAt` to
#    return `[]` — the one-line degradation this whole retirement risks — rebuild,
#    and run this gate.  MEASURED on that binary: all THREE legs below go red,
#    alias-visible and -run with `Type mismatch: Int vs Sec` at exit 1 (the alias
#    stayed an opaque `TCon`), and alias-cycle-importer with `definer hits=2
#    importer hits=0` — i.e. failing in exactly the loud→silent direction it exists
#    to guard.  An empty, mis-ordinalled, or over-filtered K seed reds these legs.
cat > "$TMP/aliaslib.mdk" <<'EOF'
export type Sec = Int

export mk : Int -> Sec
mk n = n
EOF
cat > "$TMP/aliasuse.mdk" <<'EOF'
import aliaslib.{Sec, mk}

use : Sec -> Int
use s = s + 1

main = println (use (mk 41))
EOF
alias_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/aliasuse.mdk" 2>&1)"
alias_code=$?
case "$alias_out" in
  *"use : Int -> Int"*) if [ "$alias_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   1512-A32b/alias-visible (imported alias expands; K seed live)\n'
                  else fail=$((fail+1)); printf 'FAIL 1512-A32b/alias-visible (expanded but exit %d)\n' "$alias_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL 1512-A32b/alias-visible (imported alias did not expand, exit %d: [%s])\n' "$alias_code" "$alias_out" ;;
esac
alias_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/aliasuse.mdk" 2>&1)"
alias_run_code=$?
if [ "$alias_run_code" -eq 0 ] && [ "$alias_run" = "42" ]; then
  pass=$((pass+1)); printf 'ok   1512-A32b/alias-visible-run (42)\n'
else
  fail=$((fail+1)); printf 'FAIL 1512-A32b/alias-visible-run (exit %d, got [%s], want 42)\n' "$alias_run_code" "$alias_run"
fi

#    (b) alias-cycle-importer.  🚨 THE LOUD→SILENT GUARD, and the reason it is a gate
#    leg rather than a comment.  `rejectCyclicAliases` DELETES cyclic entries from the
#    per-run table so the expansion seam cannot recurse — but that deletion never
#    reached the retired accumulator (`appendDataUniverse` RELOADS the working ref
#    before it registers and stores), so the cross-module alias source has always
#    carried cyclic entries and EVERY module re-detects them through its own
#    `rejectCyclicAliases` call.  `aliasUniverseAt` reproduces that by filtering on
#    visibility ONLY.  A future edit that pre-drops cyclic aliases from the K
#    projection would silence the IMPORTER's `T-RECURSIVE-ALIAS` while leaving the
#    declaring module's — a defect made quieter, i.e. a severity increase.  This leg
#    requires the diagnostic to name BOTH files, and `bound` proves termination (a
#    seam that recursed would hit the alarm instead).
cat > "$TMP/cyclib.mdk" <<'EOF'
export type A = B

export type B = A

export mk : Int -> Int
mk n = n
EOF
cat > "$TMP/cycuse.mdk" <<'EOF'
import cyclib.{A, mk}

use : A -> Int
use s = mk 1

main = println (use 3)
EOF
cyc_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/cycuse.mdk" 2>&1)"
cyc_code=$?
cyc_lib="$(printf '%s\n' "$cyc_out" | grep -c 'cyclib.mdk:.*Recursive type alias')"
cyc_ent="$(printf '%s\n' "$cyc_out" | grep -c 'cycuse.mdk:.*Recursive type alias')"
if [ "$cyc_code" -eq 1 ] && [ "$cyc_lib" -ge 1 ] && [ "$cyc_ent" -ge 1 ]; then
  pass=$((pass+1)); printf 'ok   1512-A32b/alias-cycle-importer (both modules diagnose; no recursion)\n'
else
  fail=$((fail+1)); printf 'FAIL 1512-A32b/alias-cycle-importer (exit %d, definer hits=%s importer hits=%s: [%s])\n' "$cyc_code" "$cyc_lib" "$cyc_ent" "$cyc_out"
fi

# ── Stage A "Door 4b": a GROUND unrouted-evidence goal is a LOUD reject ──────
#
# 🚨 THIS LEG EXISTS BECAUSE THE MUST-FAIL PIN FOR IT CANNOT BE WRITTEN.  The defect
# it guards is #1564's segfault ONE TYPE SIGNATURE AWAY from #1564's own fixture:
# with `export nest : Int -> String` the goal `Tag (Wrap Int)` is GROUND, never
# becomes a residual predicate, and so never reaches Door 4's guard
# (`unroutedResidual`, whose single call site is `residualPredsOf`'s `None` arm).
# MEASURED at `0b953165`: `check` exit 0, `build` exit 0, and the built binary exit
# **139**.  A `must_fail_fixtures/` row could not carry it once fixed — its
# `build-run` verb needs a binary, and after the fix `medaka build` correctly refuses
# (that verb returns 126 MALFORMED, never a gradeable observation), while re-using
# `issue: 1564` would trip that suite's one-fixture-per-issue check.  So the
# regression assertion lives here, where ACCEPTANCE and the BUILT BINARY are both
# observable in one gate.
#
# ⚠️ THE THIRD LEG IS THE LOAD-BEARING ONE.  Legs 1-2 only say "still rejects", which
# a too-broad reject also satisfies; leg 3 is the NARROWING guard — the control order
# must still build AND its binary must still print `wrap(int)`.  A guard that ate the
# control would be the false-reject direction RUN-047 names as this unit's inverted
# risk.
#
# 🪦 LEGS 1-2 ARE NOW DRAIN ASSERTIONS, NOT REJECT ASSERTIONS (ARCH B-2.1-b2 / B-2.1-f,
# Stage B sprint).  `B-2.1-b2` moved all three selection legs onto the graph-global
# `IE`, so the impl in the topologically-later module IS a candidate here and its
# `requires` IS recovered — the program compiles and its binary is CORRECT.  Verified
# on the built binary, not on `check`: this order's emitted IR is byte-identical to the
# control order's, so there is nothing left for Door 4 to report and no 139 to guard
# against.  ⚠️ **The legs are NOT deleted, and that matters**: the defect this block
# exists for is a WRONG BINARY at exit 0, so leg 1 keeps asserting acceptance *and* leg
# 2 keeps asserting the binary's OUTPUT.  A future regression that re-silences this
# shape reappears as a wrong `wrap(int)`, which leg 2 still sees.  What was deleted
# would have been the only assertion in the tree watching it.
# ⚠️ ONE same-head impl is the whole reason these two drain while `SA-4c` (below) does
# NOT: with a single `Wrap`-headed impl the graph-global collision count is 1, so
# `B-2.1-f`'s route-word guard cannot fire.  `SA-4c` adds a second and it does.
mkdir -p "$TMP/d4b"
cat > "$TMP/d4b/iface.mdk" <<'EOF'
public export data Wrap a = Wrap a

export interface Tag t where
  tagOf : t -> String

export impl Tag Int where
  tagOf _ = "int"
EOF
cat > "$TMP/d4b/wrapimpl.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}

export impl Tag (Wrap a) requires Tag a where
  tagOf (Wrap x) = "wrap(\{tagOf x})"
EOF
# The ONLY delta vs #1564's nest.mdk: a declared signature, which grounds the goal.
cat > "$TMP/d4b/nest.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}

export nest : Int -> String
nest x = tagOf (Wrap x)
EOF
cat > "$TMP/d4b/main.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}
import nest.{nest}
import wrapimpl

main = println (nest 5)
EOF
cat > "$TMP/d4b/control.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}
import wrapimpl
import nest.{nest}

main = println (nest 5)
EOF
d4b_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check --json "$TMP/d4b/main.mdk" 2>&1)"
d4b_code=$?
d4b_hits="$(printf '%s\n' "$d4b_out" | grep -c 'T-REQUIRES-UNROUTED\|T-ROUTE-WORD-AMBIGUOUS')"
if [ "$d4b_code" -eq 0 ] && [ "$d4b_hits" -eq 0 ]; then
  pass=$((pass+1)); printf 'ok   D4b/ground-goal-unrouted-DRAINED (accepts; evidence recovered graph-globally)\n'
else
  fail=$((fail+1)); printf 'FAIL D4b/ground-goal-unrouted-DRAINED (exit %d, code hits=%s — the drain regressed: [%s])\n' "$d4b_code" "$d4b_hits" "$d4b_out"
fi
# The build arm, separately, and it is now the LOAD-BEARING half of the drain: this leg
# is what watches for the 139 coming back, because a re-silenced route stamps a wrong
# impl rather than refusing.  So it grades the BINARY'S OUTPUT, not merely its exit.
# Its exit code is read from a variable, never through a pipe.
MEDAKA_ROOT="$ROOT" bound "$MEDAKA" build "$TMP/d4b/main.mdk" -o "$TMP/d4b.bin" >"$TMP/d4b.buildlog" 2>&1
d4b_bcode=$?
if [ "$d4b_bcode" -eq 0 ] && [ -x "$TMP/d4b.bin" ]; then
  d4b_bexec="$("$TMP/d4b.bin" 2>/dev/null | head -1)"
  d4b_bexit=$?
else
  d4b_bexec="!!BUILD-FAILED"
  d4b_bexit=-1
fi
if [ "$d4b_bcode" -eq 0 ] && [ "$d4b_bexec" = "wrap(int)" ]; then
  pass=$((pass+1)); printf 'ok   D4b/ground-goal-unrouted-binary-correct (builds; binary prints wrap(int))\n'
else
  fail=$((fail+1)); printf 'FAIL D4b/ground-goal-unrouted-binary-correct (build exit %d, binary [%s] exit %s — want wrap(int); the 139 shape may be back)\n' "$d4b_bcode" "$d4b_bexec" "$d4b_bexit"
fi
d4b_cchk="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/d4b/control.mdk" 2>&1)"
d4b_ccode=$?
if MEDAKA_ROOT="$ROOT" bound "$MEDAKA" build "$TMP/d4b/control.mdk" -o "$TMP/d4bc.bin" >/dev/null 2>&1 && [ -x "$TMP/d4bc.bin" ]; then
  d4b_cbld="$("$TMP/d4bc.bin" 2>/dev/null | head -1)"
else
  d4b_cbld="!!BUILD-FAILED"
fi
if [ "$d4b_ccode" -eq 0 ] && [ "$d4b_cbld" = "wrap(int)" ]; then
  pass=$((pass+1)); printf 'ok   D4b/ground-goal-control-still-compiles (binary prints wrap(int))\n'
else
  fail=$((fail+1)); printf 'FAIL D4b/ground-goal-control-still-compiles (check exit %d, binary [%s], want wrap(int): [%s])\n' "$d4b_ccode" "$d4b_cbld" "$d4b_cchk"
fi
# The OTHER narrowing direction, and the one that decides how broad the new guard is:
# a matching impl in the SAME unimported later module but with NO `requires` needs no
# dictionary at all (R5 measured `define i64 @mdk_nest__nest(i64 %arg0)`, arity 1), so
# it must still compile and RUN.  `unroutedGroundReqs` is deliberately narrower than
# Door 4's own guard for exactly this program.
mkdir -p "$TMP/d4c"
cp "$TMP/d4b/iface.mdk" "$TMP/d4c/iface.mdk"
cp "$TMP/d4b/nest.mdk"  "$TMP/d4c/nest.mdk"
cp "$TMP/d4b/main.mdk"  "$TMP/d4c/main.mdk"
cat > "$TMP/d4c/wrapimpl.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}

export impl Tag (Wrap Int) where
  tagOf _ = "wrap-noreq"
EOF
d4c_chk="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/d4c/main.mdk" 2>&1)"
d4c_code=$?
d4c_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/d4c/main.mdk" 2>&1)"
d4c_rcode=$?
if [ "$d4c_code" -eq 0 ] && [ "$d4c_rcode" -eq 0 ] && [ "$d4c_run" = "wrap-noreq" ]; then
  pass=$((pass+1)); printf 'ok   D4b/no-requires-impl-still-accepted (nothing to route, nothing rejected)\n'
else
  fail=$((fail+1)); printf 'FAIL D4b/no-requires-impl-still-accepted (check %d, run %d [%s]) — the guard is too broad\n' "$d4c_code" "$d4c_rcode" "$d4c_run"
fi

# 23. SA-3 (sprint repair round, owner ruling RUN-055) — THE SUPERINTERFACE-EXISTENCE
#     CHECK IS GRAPH-GLOBAL, LIKE CANDIDACY.  A-3.6 made instance candidacy
#     graph-global on the INSTANCE axis alone; `checkSuperImpls` kept scanning `IE`'s
#     rows at the reading module's ORDINAL, so the two channels disagreed inside one
#     program: an `impl Sup W` in a topologically LATER module was a dispatch
#     candidate AND was reported missing by the check beside it.  Ruled: widen the
#     check (`ieRowsVisibleAt` → `ieCandidacyVisibleAt`).
#
#     🚨 THIS IS AN ACCEPTANCE WIDENING, so leg (a) is a COULD-NOT-PASS-BEFORE
#     program — rejected at exit 1 by the binary at 06d13c3a, exit 0 and printing 42
#     after.  Every pre-existing fixture covered the rejecting case, so nothing else
#     in this tree can fail if the widening is wrong in the accepting direction.
#     Legs (b)-(d) are the must-not-move half: the check must still be ABLE to fail,
#     on BOTH driver arms, or the widening deleted it rather than fixing it.
#
#       (a) later-super-accepted   — the widening itself (Module arm).
#       (b) super-absent-rejects   — Module arm, the super exists NOWHERE in the
#           graph: `T-MISSING-SUPER-IMPL` must still fire.
#       (c) flat-super-absent      — the FLAT arm, which reaches this check through
#           `flatImplEnvOf` at ordinal 0 with `cur = 0`.  There "visible at" and
#           "candidacy" already coincided, so the widening is a NO-OP on Flat by
#           construction; this leg is what makes that claim falsifiable rather than
#           argued, and it is the arm where an accidental widening would turn a live
#           rejection into a silent accept.
#       (d) same-spelled-super     — 🎯 THE NEAREST MISS.  Identical to (a) except
#           that the later module's `impl Sup W` implements a DIFFERENT `Sup`, from
#           an unrelated module, that merely shares the spelling.  It must STILL
#           reject: `implRowMatchesSuper` decides on the IDENTITY key
#           (`ifaceTabKey ir.irOrigin ir.irName`), and the bare-spelling leg exists
#           only in `IE`'s buckets, which this query never reads.  If (d) ever goes
#           green the widening leaked onto the spelling axis and rebuilt #1438 here.
mkdir -p "$TMP/sa3"
cat > "$TMP/sa3/iface.mdk" <<'EOF'
export interface Sup a where
  sf : a -> Int

export interface Sub a requires Sup a where
  ufn : a -> Int

public export data W = W
EOF
cat > "$TMP/sa3/subimpl.mdk" <<'EOF'
import iface.{Sup, sf, Sub, ufn, W}

export impl Sub W where
  ufn x = sf x + 35
EOF
cat > "$TMP/sa3/supimpl.mdk" <<'EOF'
import iface.{Sup, sf, W}

export impl Sup W where
  sf _ = 7
EOF
# `subimpl` first ⇒ loader order iface, subimpl, supimpl, main ⇒ the super impl sits
# at a HIGHER ordinal than the `impl Sub W` that needs it.  That is the whole variable.
cat > "$TMP/sa3/main.mdk" <<'EOF'
import iface.{W, ufn}
import subimpl
import supimpl

main = println (ufn W)
EOF
sa3_chk="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/sa3/main.mdk" 2>&1)"
sa3_code=$?
sa3_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/sa3/main.mdk" 2>&1)"
sa3_rcode=$?
if [ "$sa3_code" -eq 0 ] && [ "$sa3_rcode" -eq 0 ] && [ "$sa3_run" = "42" ]; then
  pass=$((pass+1)); printf 'ok   SA-3/later-super-accepted (existence is graph-global; runs, prints 42)\n'
else
  fail=$((fail+1)); printf 'FAIL SA-3/later-super-accepted (check %d [%s], run %d [%s], want exit 0 / 42)\n' "$sa3_code" "$sa3_chk" "$sa3_rcode" "$sa3_run"
fi

# (b) the same graph with `supimpl` deleted: the super is in NO module.
mkdir -p "$TMP/sa3b"
cp "$TMP/sa3/iface.mdk"   "$TMP/sa3b/iface.mdk"
cp "$TMP/sa3/subimpl.mdk" "$TMP/sa3b/subimpl.mdk"
cat > "$TMP/sa3b/main.mdk" <<'EOF'
import iface.{W, ufn}
import subimpl

main = println (ufn W)
EOF
sa3b_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/sa3b/main.mdk" 2>&1)"
sa3b_code=$?
case "$sa3b_out" in
  *"requires a superinterface 'impl Sup W', which is missing"*)
    if [ "$sa3b_code" -eq 1 ]; then
      pass=$((pass+1)); printf 'ok   SA-3/super-absent-rejects (the check can still fail — Module arm)\n'
    else
      fail=$((fail+1)); printf 'FAIL SA-3/super-absent-rejects (right diagnostic, wrong exit %d)\n' "$sa3b_code"
    fi ;;
  *) fail=$((fail+1)); printf 'FAIL SA-3/super-absent-rejects (T-MISSING-SUPER-IMPL gone — the widening DELETED the check, exit %d: [%s])\n' "$sa3b_code" "$sa3b_out" ;;
esac

# (c) FLAT arm: one file, no imports, super missing.
cat > "$TMP/sa3flat.mdk" <<'EOF'
interface Sup a where
  sf : a -> Int

interface Sub a requires Sup a where
  ufn : a -> Int

data W = W

impl Sub W where
  ufn x = sf x + 35

main = println 1
EOF
sa3f_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/sa3flat.mdk" 2>&1)"
sa3f_code=$?
case "$sa3f_out" in
  *"requires a superinterface 'impl Sup W', which is missing"*)
    if [ "$sa3f_code" -eq 1 ]; then
      pass=$((pass+1)); printf 'ok   SA-3/flat-super-absent (the check can still fail — Flat arm)\n'
    else
      fail=$((fail+1)); printf 'FAIL SA-3/flat-super-absent (right diagnostic, wrong exit %d)\n' "$sa3f_code"
    fi ;;
  *) fail=$((fail+1)); printf 'FAIL SA-3/flat-super-absent (live rejection became a silent accept on Flat, exit %d: [%s])\n' "$sa3f_code" "$sa3f_out" ;;
esac

# (d) the nearest miss: a same-spelled `Sup` from an unrelated module.
mkdir -p "$TMP/sa3d"
cp "$TMP/sa3/iface.mdk"   "$TMP/sa3d/iface.mdk"
cp "$TMP/sa3/subimpl.mdk" "$TMP/sa3d/subimpl.mdk"
cat > "$TMP/sa3d/otheriface.mdk" <<'EOF'
export interface Sup a where
  osf : a -> Int
EOF
cat > "$TMP/sa3d/supimpl.mdk" <<'EOF'
import otheriface.{Sup, osf}
import iface.{W}

export impl Sup W where
  osf _ = 7
EOF
cat > "$TMP/sa3d/main.mdk" <<'EOF'
import iface.{W, ufn}
import subimpl
import supimpl

main = println (ufn W)
EOF
sa3d_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/sa3d/main.mdk" 2>&1)"
sa3d_code=$?
case "$sa3d_out" in
  *"requires a superinterface 'impl Sup W', which is missing"*)
    if [ "$sa3d_code" -eq 1 ]; then
      pass=$((pass+1)); printf 'ok   SA-3/same-spelled-super (identity decides; the spelling does not)\n'
    else
      fail=$((fail+1)); printf 'FAIL SA-3/same-spelled-super (right diagnostic, wrong exit %d)\n' "$sa3d_code"
    fi ;;
  *) fail=$((fail+1)); printf 'FAIL SA-3/same-spelled-super (a DIFFERENT interface sharing the spelling satisfied the super — #1438 rebuilt, exit %d: [%s])\n' "$sa3d_code" "$sa3d_out" ;;
esac

# 24. SA-4 (sprint repair round, owner ruling RUN-055) — DOOR 4 ONLY FIRES WHERE A
#     DICTIONARY WOULD ACTUALLY HAVE TO BE PASSED.  Door 4's guard shipped as
#     `implMatchesU` alone: bare EXISTENCE, never asking whether the matched impl
#     carries a `requires`.  So it also rejected the case whose correct answer is `[]`
#     on BOTH arms — a matching impl with NO `requires` needs no dict at all, and the
#     message's own claim ("accepting it would build a program that reads a dictionary
#     that was never passed") is false for it.  Ruled: test `implMatchesWithReqsU`, the
#     predicate SA-1 already added at the sibling ground site.
#
#     🚨 ACCEPTANCE WIDENING, so leg (a) is a COULD-NOT-PASS-BEFORE program.  MEASURED
#     on the binary at e9f917f2: `check` exit 1 with `T-REQUIRES-UNROUTED` at
#     `nest.mdk:3:16`.  After: check/run/build exit 0 and the built binary prints
#     `wrap`.  It RESTORES what BASE did — BASE never reached this code at all — which
#     is why a base-vs-head comparison is this widening's justification.
#     The accepted program is CORRECT, not merely accepted: `build --keep-ir` on the
#     previously-rejecting order emits `define i64 @mdk_nest__nest(i64 %arg0)` and
#     `define i64 @mdk_impl_Wrap_tagOf(i64 %arg0)` — arity 1 on both sides, no dict
#     parameter anywhere, so there is nothing to mis-route.  (Re-taken on THIS binary;
#     R5's original read was on the control order.)
#
#       (a) no-requires-residual-accepted — the widening itself.  The DEFERRED goal
#           (no signature on `nest`), which is the arm `unroutedResidual` owns; the
#           GROUND arm of the same shape is already covered by D4b/no-requires above.
#       (b) requires-impl-still-rejects  — the must-not-move half.  Same four modules,
#           same import order, the impl given back its `requires`: this is #1564's own
#           program and it must STILL reject.  A widening that cannot fail deleted the
#           check rather than fixing it.
#       (c) 🎯 THE NEAREST MISS, and it is a KNOWN RETAINED FALSE REJECT — asserted so
#           it is recorded rather than discovered.  `implMatchesWithReqsU` is
#           DISJUNCTIVE: "some impl matching these args carries reqs", not "the impl
#           that would be SELECTED does".  With BOTH `impl Tag (Wrap a) requires Tag a`
#           and the more specific `impl Tag (Wrap Int)` in the unimported later module,
#           a ground `Tag (Wrap Int)` goal still rejects — even though the control
#           order selects the specific one and prints `wrap-int-specific`, needing no
#           dictionary.  That is deliberate and it is the LOUD direction: the selector
#           that would name the winner is the very registry that just failed, so the
#           guard cannot ask which impl wins without re-introducing the split it is
#           reporting.  If (c) ever flips to accepting, someone taught the guard to
#           pick a winner from the starved registry — check what it emits before
#           calling that a fix.
#           🚨 THAT WARNING CAME DUE, AND IT WAS RIGHT (ARCH B-2.1-b2 → B-2.1-f).
#           `B-2.1-b2` moved the three SELECTION legs graph-global and (c) DID flip to
#           accepting — over a **built binary that exited 139**: the site emitted
#           `call @mdk_impl_Tag__Wrap_a___tagOf(i64 %t2)`, an arity-2 conditional impl
#           called with ONE argument, because the METHOD-keyed ROUTE WORD was left on
#           the prefix table (AM-1) and the prefix count at head `Wrap` is 0 where the
#           graph's is 2.  This leg was the ONLY assertion in the tree that could see
#           it, and its own header is what made the diagnosis five minutes rather than
#           a session.  `B-2.1-f` re-armed the reject: it is now
#           `T-ROUTE-WORD-AMBIGUOUS`, from a NEW guard on the route word's own
#           collision-count disagreement, and NOT `T-REQUIRES-UNROUTED` — the impl
#           min⊑ actually selects here carries no `requires`, so Door 4's *"Cannot pass
#           a dictionary"* would misname the cause.  ⚠️ THE ASSERTED VERBS CHANGED: the
#           reject is observable on `build`/`run`, and `check` is STRUCTURALLY BLIND to
#           the route-word channel (its driver runs neither the MARK nor the stamp
#           pass).  That split is pinned as its own row below rather than hidden.
#           🚨 ARCH B-2.1-g CLOSED ALL OF THAT AND BOTH SA-4c LEGS ARE RE-CUT BELOW.
#           `keyForSite` now selects and counts over the graph-global
#           `perRun.bodyImplEnvRef`, so the prefix-vs-graph disagreement no longer
#           exists: `f`'s guard is unreachable, `T-ROUTE-WORD-AMBIGUOUS` is retired, and
#           the program BUILDS AND RUNS CORRECTLY in both import orders.  The
#           `check`-blindness row is retired WITH it — with nothing to report, `check 0`
#           is simply the right answer for a legal program, so pinning it would assert
#           nothing.  ⚠️ Both legs were re-cut DELIBERATELY, not to make a red go away:
#           the replacement grades what the fix actually establishes (the SELECTED impl
#           is the arity-1 specific one, and the two import orders agree), which is
#           strictly harder to satisfy than either predecessor.
mkdir -p "$TMP/sa4"
cat > "$TMP/sa4/iface.mdk" <<'EOF'
public export data Wrap a = Wrap a

export interface Tag t where
  tagOf : t -> String

export impl Tag Int where
  tagOf _ = "int"
EOF
cat > "$TMP/sa4/wrapimpl.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}

export impl Tag (Wrap a) where
  tagOf _ = "wrap"
EOF
cat > "$TMP/sa4/nest.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}

export nest x = tagOf (Wrap x)
EOF
# `nest` before `wrapimpl` ⇒ the impl's module sorts LATER than the goal's own.  That
# is the whole variable; every other file is byte-identical to #1564's fixture.
cat > "$TMP/sa4/main.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}
import nest.{nest}
import wrapimpl

main = println (nest 5)
EOF
sa4_chk="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/sa4/main.mdk" 2>&1)"
sa4_code=$?
MEDAKA_ROOT="$ROOT" bound "$MEDAKA" build "$TMP/sa4/main.mdk" -o "$TMP/sa4.bin" >"$TMP/sa4.buildlog" 2>&1
sa4_bcode=$?
if [ "$sa4_bcode" -eq 0 ] && [ -x "$TMP/sa4.bin" ]; then
  sa4_exec="$("$TMP/sa4.bin" 2>/dev/null | head -1)"
else
  sa4_exec="!!BUILD-FAILED"
fi
if [ "$sa4_code" -eq 0 ] && [ "$sa4_exec" = "wrap" ]; then
  pass=$((pass+1)); printf 'ok   SA-4/no-requires-residual-accepted (no dict to route; binary prints wrap)\n'
else
  fail=$((fail+1)); printf 'FAIL SA-4/no-requires-residual-accepted (check %d [%s], build %d, binary [%s], want exit 0 / wrap)\n' "$sa4_code" "$sa4_chk" "$sa4_bcode" "$sa4_exec"
fi

# (b) the same graph with the `requires` put back — #1564's own program.
mkdir -p "$TMP/sa4b"
cp "$TMP/sa4/iface.mdk" "$TMP/sa4/nest.mdk" "$TMP/sa4/main.mdk" "$TMP/sa4b/"
cat > "$TMP/sa4b/wrapimpl.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}

export impl Tag (Wrap a) requires Tag a where
  tagOf (Wrap x) = "wrap(\{tagOf x})"
EOF
sa4b_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check --json "$TMP/sa4b/main.mdk" 2>&1)"
sa4b_code=$?
sa4b_hits="$(printf '%s\n' "$sa4b_out" | grep -c 'T-REQUIRES-UNROUTED\|T-ROUTE-WORD-AMBIGUOUS')"
MEDAKA_ROOT="$ROOT" bound "$MEDAKA" build "$TMP/sa4b/main.mdk" -o "$TMP/sa4b.bin" >"$TMP/sa4b.buildlog" 2>&1
sa4b_bcode=$?
if [ "$sa4b_bcode" -eq 0 ] && [ -x "$TMP/sa4b.bin" ]; then
  sa4b_exec="$("$TMP/sa4b.bin" 2>/dev/null | head -1)"
else
  sa4b_exec="!!BUILD-FAILED"
fi
if [ "$sa4b_code" -eq 0 ] && [ "$sa4b_hits" -eq 0 ] && [ "$sa4b_exec" = "wrap(int)" ]; then
  pass=$((pass+1)); printf 'ok   SA-4/requires-impl-DRAINED (#1564 accepts; binary prints wrap(int))\n'
else
  fail=$((fail+1)); printf 'FAIL SA-4/requires-impl-DRAINED (check %d, hits=%s, build %d, binary [%s], want exit 0 / wrap(int): [%s])\n' "$sa4b_code" "$sa4b_hits" "$sa4b_bcode" "$sa4b_exec" "$sa4b_out"
fi

# (c) the nearest miss: both impls present, the SELECTED one needs no dict, and the
#     disjunctive guard rejects anyway.  Asserted as REJECTING, on purpose.
mkdir -p "$TMP/sa4c"
cp "$TMP/sa4/iface.mdk" "$TMP/sa4/main.mdk" "$TMP/sa4c/"
cat > "$TMP/sa4c/nest.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}

export nest : Int -> String
nest x = tagOf (Wrap x)
EOF
cat > "$TMP/sa4c/wrapimpl.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}

export impl Tag (Wrap a) requires Tag a where
  tagOf (Wrap x) = "wrap(\{tagOf x})"

export impl Tag (Wrap Int) where
  tagOf _ = "wrap-int-specific"
EOF
cat > "$TMP/sa4c/control.mdk" <<'EOF'
import iface.{Tag, tagOf, Wrap}
import wrapimpl
import nest.{nest}

main = println (nest 5)
EOF
# 🚨 THE ARM THAT WAS MISSING, AND ITS ABSENCE IS HOW THE S0 GOT IN (ARCH B-2.1-f).
# Every assertion in this block used to grade `check` ALONE.  `B-2.1-b2` silenced this
# shape and the silent state was a `build` at exit 0 whose BINARY exited **139** — so a
# `check`-only assertion set is structurally blind to exactly the failure this block
# exists for.  So this leg grades the BUILT BINARY's own output, on BOTH import orders.
# Exit codes read from variables, never through a pipe (`build`'s status does not
# survive one).
#
# 🚨 RE-CUT BY ARCH B-2.1-g, AND THE DIRECTION MATTERS: it went from "build must REFUSE"
# (`f`'s stand-in reject) to "build must SUCCEED and the binary must print
# `wrap-int-specific` in BOTH orders".  That is not a relaxation.  The three states this
# shape has been through are, in order: `b2` — build 0, binary **139** (S0); `f` — build
# 1, no binary (loud false reject, S2); `g` — build 0, binary correct, BOTH orders.  The
# assertion below fails on EITHER of the first two, so it is fail-capable against the
# whole history and not merely against today.
# Written out per arm rather than looped: a loop needs `eval` to build the per-arm
# variable names, and `eval` around a `$?` read is exactly the kind of shell that passes
# for the wrong reason (this gate's own header warns about dash's byte/exit traps).
rm -f "$TMP/sa4c.main.bin" "$TMP/sa4c.main.bin.ll"
MEDAKA_ROOT="$ROOT" bound "$MEDAKA" build --keep-ir "$TMP/sa4c/main.mdk" -o "$TMP/sa4c.main.bin" >"$TMP/sa4c.main.buildlog" 2>&1
sa4c_bm=$?
if [ -x "$TMP/sa4c.main.bin" ]; then
  sa4c_em="$("$TMP/sa4c.main.bin" 2>/dev/null | head -1)"
else
  sa4c_em="!!NO-BINARY"
fi
rm -f "$TMP/sa4c.control.bin" "$TMP/sa4c.control.bin.ll"
MEDAKA_ROOT="$ROOT" bound "$MEDAKA" build --keep-ir "$TMP/sa4c/control.mdk" -o "$TMP/sa4c.control.bin" >"$TMP/sa4c.control.buildlog" 2>&1
sa4c_bc=$?
if [ -x "$TMP/sa4c.control.bin" ]; then
  sa4c_ec="$("$TMP/sa4c.control.bin" 2>/dev/null | head -1)"
else
  sa4c_ec="!!NO-BINARY"
fi
if [ "$sa4c_bm" -eq 0 ] && [ "$sa4c_bc" -eq 0 ] \
  && [ "$sa4c_em" = "wrap-int-specific" ] && [ "$sa4c_ec" = "wrap-int-specific" ]; then
  pass=$((pass+1)); printf 'ok   SA-4c/overlap-DRAINED-both-orders (build 0 both orders; binary prints wrap-int-specific)\n'
else
  fail=$((fail+1)); printf 'FAIL SA-4c/overlap-DRAINED-both-orders (build %s/%s, binary [%s]/[%s] — want 0/0 and wrap-int-specific twice)\n' "$sa4c_bm" "$sa4c_bc" "$sa4c_em" "$sa4c_ec"
fi
# 🚨 AND THIS IS THE MECHANISM LEG — the one that would have caught `b2`'s S0 directly,
# and the replacement for `B-2.1-f`'s now-retired `check`-blindness row.
#
# Why the predecessor had to go rather than be kept: it pinned `check` exiting 0 on this
# project as a KNOWN-WRONG state, because `build` rejected while `check` could not see
# the route-word channel.  With the channel gone there is nothing to report, so `check 0`
# is simply the CORRECT answer for a legal program — the row would have gone on passing
# while asserting nothing.  An exit-code-graded row over a program that should check
# clean cannot discriminate; grade the MECHANISM instead.
#
# What this grades: the two import orders must emit the SAME IR, and that IR must call
# the ARITY-1 specific impl (`@mdk_impl_Tag__Wrap_Int___tagOf` with ONE argument).  Both
# halves are load-bearing and neither implies the other:
#   * a byte-identical diff alone would pass if BOTH orders were equally wrong;
#   * the arity check alone would pass on the accepting order while the other segfaulted
#     — which is exactly `b2`'s state (there, `nest` emitted
#     `call @mdk_impl_Tag__Wrap_a___tagOf(i64 %t2)`: an arity-2 define called with ONE
#     argument, the value cell landing in the dict slot, hence the 139).
# So the pair is the discriminator, and the route word is what makes them agree.
#
# ⚠️ THE SYMBOL IS NOW MODULE-QUALIFIED, AND BOTH GREPS TOLERATE THAT DELIBERATELY.
# ARCH B-2.2-b1/e made the impl route word carry the interface's origin, so this callee
# went from `@mdk_impl_Tag__Wrap_Int___tagOf` to `@mdk_impl_iface__Tag__Wrap_Int___tagOf`.
# The old LITERAL grep found nothing and this leg reddened in CI with an empty capture,
# which reads exactly like "the specific impl is not the callee" — i.e. like a dispatch
# regression. It was not: measured at that commit, both orders BUILD, both binaries print
# `wrap-int-specific`, and the two IRs are BYTE-IDENTICAL.
# The patterns below therefore allow an optional `<module>__` prefix and NOTHING ELSE.
# Both load-bearing halves are intact: the `(i64 %x)$` anchor still pins ARITY 1 (a
# one-argument call at end of line), and `Wrap_Int` still pins the SPECIFIC impl over the
# general `Wrap_a` one. Do not relax either to silence a future red — a red here means
# the orders diverged or the general impl won, and both are the S0 this leg exists for.
if [ ! -f "$TMP/sa4c.main.bin.ll" ] || [ ! -f "$TMP/sa4c.control.bin.ll" ]; then
  fail=$((fail+1)); printf 'FAIL SA-4c/route-word-order-invariant (no IR kept — build refused, see the leg above)\n'
elif diff "$TMP/sa4c.main.bin.ll" "$TMP/sa4c.control.bin.ll" >/dev/null 2>&1 \
  && grep -qE 'call i64 @mdk_impl_[A-Za-z_0-9]*Tag__Wrap_Int___tagOf\(i64 %[a-z0-9]*\)$' "$TMP/sa4c.main.bin.ll"; then
  pass=$((pass+1)); printf 'ok   SA-4c/route-word-order-invariant (both orders IR-identical; arity-1 specific impl called)\n'
else
  sa4c_site="$(grep -oE 'call i64 @mdk_impl_[A-Za-z_0-9]*Tag__Wrap[A-Za-z_0-9]*\(i64[^)]*\)' "$TMP/sa4c.main.bin.ll" | head -2 | tr '\n' ' ')"
  fail=$((fail+1)); printf 'FAIL SA-4c/route-word-order-invariant (IR differs between import orders, or the specific impl is not the arity-1 callee: [%s])\n' "$sa4c_site"
fi

# 25. SA-6 (sprint repair round) — `runFinalChecks`' `-1` ordinal sentinel is LOUD.
#     `declEnvsOrdOf`'s miss value reaches all four final checks, and at `-1` every one
#     of them abstains: coherence takes `cohRowsOwnedBy -1` (no rows), cycles/phantom
#     take `ceRowsVisibleAt -1`/`ceRowsOwnedBy -1`, and super-existence finds no SUPERS
#     through `ceLookupAt … -1`.  The tail degraded to a SILENT ACCEPT, which is the
#     loud→silent transition this repo ranks as a severity increase.  It is unreachable
#     from the three current drivers, so what this leg can assert is the FALSE-POSITIVE
#     direction — the half that would actually break users.  `ordinalIsSentinel`'s
#     doctests carry the true half.
#     🎯 NOT COVERED, stated rather than implied: a driver threading a VALID-but-WRONG
#     ordinal is undetectable (only the sentinel self-identifies), and
#     `globalCoherenceConflict` takes no ordinal at all.
sa6_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/sa3/main.mdk" 2>&1)"
sa6_code=$?
sa6_flat="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/sa3flat.mdk" 2>&1)"
case "$sa6_out$sa6_flat" in
  *T-INTERNAL-ORDINAL*|*"unknown module ordinal"*)
    fail=$((fail+1)); printf 'FAIL SA-6/sentinel-does-not-fire (the guard fires on a LIVE driver — spurious: [%s][%s])\n' "$sa6_out" "$sa6_flat" ;;
  *)
    if [ "$sa6_code" -eq 0 ]; then
      pass=$((pass+1)); printf 'ok   SA-6/sentinel-does-not-fire (Module and Flat arms both reach a real ordinal)\n'
    else
      fail=$((fail+1)); printf 'FAIL SA-6/sentinel-does-not-fire (Module arm stopped checking clean, exit %d: [%s])\n' "$sa6_code" "$sa6_out"
    fi ;;
esac

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
