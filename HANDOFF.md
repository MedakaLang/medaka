# HANDOFF — next things to tackle

_Last updated 2026-06-27._

## Context

The **L2 structured-runtime-dict task is already DONE** (verified 2026-06-27, no
work needed). The boxed-witness tree dict rep shipped 2026-06-10 (`205b4de`,
"Option A") and the multi-module route-resolution residual closed 2026-06-11
(`argImplRequiresRoutesRec`). Nested instance dicts build==run==correct through
4+ levels, polymorphic forwarding, and multi-module. The stale
`TYPECHECK-AUDIT.md §L2` "still open" label was corrected in this commit.

A reproduce-first sweep then surfaced **four distinct `run≠build` codegen bugs**
(interpreter `run` is the correct oracle; native `build` miscompiles; `medaka
check` accepts all four). They survive self-compile because the compiler's own
source never uses these forms. These are the next things to tackle, in priority
order.

## How to reproduce / build (read `AGENTS.md` first)

```sh
# warm build (needs ./medaka_emitter; copy from main checkout if absent)
make -C <worktree-root> medaka
# run vs build a fixture
./medaka run f.mdk
MEDAKA_ROOT=<worktree-root> MEDAKA_EMITTER=<worktree-root>/medaka_emitter \
  ./medaka build f.mdk -o /tmp/out && /tmp/out
```

Verification bar for any fix: new fixture driving the **build path** with
run==build==correct; all `diff_compiler_*` gates 0-fail;
`test/selfcompile_fixpoint.sh` C3a/C3b YES; `test/bootstrap_from_seed.sh` cold
PASS; then re-mint the seed (`sh test/refresh_seed.sh`, commit the updated
`compiler/seed/emitter.ll.gz`). `FORCE=1 bash test/build_oracles.sh` before
trusting any gate.

---

## Bug 3 — String `.[]` index/slice (TACKLE FIRST — clearest root cause, fundamental)

`"hello".[0]` returns a wrong/empty `Char` on `build`; `"hello".[1..3]` returns
wrong/empty. String runtime *functions* (`string.slice`, `startsWith`, …, which
call the `stringSlice` extern) are FINE — only the **`.[]` sugar** breaks.

```
main = println (debug ("hello".[0] == 'h'))    -- run=True ; build=False
main = println (debug (charCode ("hello".[0]))) -- run=104 ; build=oob panic
main = println ("hello".[1..3])                 -- run="el" ; build=<empty>
```

**Root cause:** `CIndex`/`CSlice` (`compiler/ir/core_ir.mdk`) carry no
receiver-type tag — `compiler/ir/core_ir_lower.mdk` lowers `EIndex a i → CIndex
(lower a) (lower i)` generically, dropping the typechecker's known
String-vs-Array distinction; the emitter `compiler/backend/llvm_emit.mdk`
`emitExpr (CIndex a i) = emitArrayIndex e env a i` unconditionally array-indexes,
so a String is read as an array of i64 cells. The interpreter's `evalIndex`
runtime-dispatches on the value tag, so `run` is correct.

**Fix direction:** thread the String/Array distinction into `CIndex`/`CSlice` at
lowering (type tag on the node, or a distinct `CStringIndex`/`CStringSlice`), and
emit a UTF-8-aware string-char-extract / substring for the String case. Note
String length is CODE POINTS, not bytes ("héllo→世" has length 7). Same
"type-lost at emit" class as the historical float-arith bugs. Memory:
`project_string_index_slice_emit_bug`.

## Bug 1 — comparison OPERATORS on a bare constraint tyvar (HIGH — silent corruption)

```
f : Eq a => a -> a -> Bool
f x y = x == y
main = println (debug (f [1, 2] [1, 2]))   -- run=True ; build=False (wrong)
```

Affects `==` `!=` `<` `<=` `>` `>=` at a non-primitive type via a forwarded class
dict. `eq x y` (direct method) works; ground / primitive `Int` works.
**Real impact:** `stdlib/hash_set.mdk bucketHas` uses `x == y`, so
`HashSet`/`HashMap` membership of any non-primitive element silently returns
WRONG results on built binaries. Ordered `Set`/`Map` are fine (they use the
`compare` method, not operators).

**Root cause:** `compiler/types/typecheck.mdk` `resolveBinopSite` (~line 5701)
leaves the route `RNone` (→ arg-tag dispatch) for a top-level constraint-var
operand instead of routing the enclosing fn's forwarded `$dict_<method>_<slot>`.
The `inImpl` gate (added to avoid stale-`activeDictVars` id collisions at
top-level operand sites) is too coarse — it also excludes legitimately-constrained
top-level operator sites.

**Fix direction:** route an operator at a bare constraint-var operand to the
enclosing top-level constrained fn's forwarded class dict (mirror the
direct-method path) WITHOUT re-introducing the collision the `inImpl` gate
guards. Lands in the fragile surviving-unify-var-id route-keying area — assert
representatives, gate carefully. Memory:
`project_comparison_operator_forwarded_dict_bug`. (Doing the D7 `(iface,id)`
re-key here is plausible but D7 is NOT observably broken even now — see memory.)

## Bug 2 — partial/escaping typeclass-method closure under a forwarded dict (HIGH — crash)

```
apply1 : (a -> b) -> a -> b
apply1 g x = g x
f : Eq a => a -> a -> Bool
f y z = apply1 (eq y) z          -- partial method `eq y` escapes into apply1
main = println (debug (f 1 1))   -- run=True ; build=<empty> (even for Int!)
```

Also: `map (eq y) xs` → SIGSEGV. Eta-expanding (`w => eq y w`) fixes it ONLY when
the closure is consumed locally; a bare dict-closure that ESCAPES its constrained
fn (`mkEq y = (z => eq y z)` returned + applied outside) SIGSEGVs even
eta-expanded (wrapping it in a ctor/record return works). GROUND partial app
(`map (eq 1) xs`) is fine.

**Root cause (hypothesis, confirm in code):** the emitter's closure free-variable
/ partial-application path (`compiler/backend/llvm_emit.mdk` `freeVars` /
under-applied `EMethodRef`) does not include the forwarded `$dict_<method>_<slot>`
in the escaping closure's environment. Related: E8 closure-dict-route capture
(EMITTER-GAPS.md line 49) and `project_nested_closure_param_capture_bug`. Memory:
`project_partial_method_closure_dict_capture_bug`.

## Bug 4 — polymorphic-Unit `main` spurious `0` (LOW — cosmetic)

```
applyEff : (a -> <IO> b) -> a -> <IO> b
applyEff f x = f x
main = applyEff (n => println (debug n)) 42   -- run: 42 ; build: 42 then a spurious 0
```

Annotating `main : <IO> Unit` (or `applyEff … -> <IO> Unit`) fixes it.

**Root cause:** the native `mainIsUnit` auto-print-suppression gate inspects
main's declared/structural type and doesn't recognize a tyvar that *resolved* to
Unit via inference → treats it as a value main → emits the trailing auto-print.
**Fix:** zonk/normalize main's type before the `mainIsUnit` check. Memory:
`project_polymorphic_unit_main_autoprint_bug`.

---

## Common thread

Three of four are "type/dict info known at typecheck but lost or not-threaded at
emit" — the same class as the historical float-arith bugs
(`project_arith_on_typelost_floats_bug`). All have minimal single-file repros and
filed memory entries with fix directions.
