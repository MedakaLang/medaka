---
name: harden-typechecker
description: Typechecker-internal work in compiler/types/ (the tc_* modules and the typecheck.mdk entry) — type errors, constraint/coherence/unification logic, over/under-generalization. Use when the fix lives inside the typechecker, not in new surface syntax.
---

# Harden the typechecker

⚠️ **Before fixing ANY typechecker bug**, answer the standing questions in
`.claude/workstreams/TYPECHECK.md` (keyed to the `ws:typecheck` label, not this skill) in writing
on the issue/PR — `typecheck.mdk`'s bug history is dominated by fixes that relocated a defect
rather than removing it.

The typechecker is the 26 `tc_*` modules plus the entry `compiler/types/typecheck.mdk`
(the graph drive and the verb-facing API). Which module owns a concern, and the spec
sections that govern it, are in `compiler/types/ARCHITECTURE.md` (the Parts table and
the module-to-spec map); the placement rules are `compiler/ARCHITECTURE-PLAYBOOK.md`
section 6. The work is narrower than `add-language-feature` (no lexer/parser/AST changes): you
are making the checker *reject more*, *diagnose better*, or *generalize
correctly*, without disturbing the two invariants below.

Read the relevant archive/PLAN-ARCHIVE.md phase first — each entry has a **Where.**
section with approximate locations and a **Done when.** acceptance test. Those
locations drift; **confirm every name with `grep` before trusting it.** (An
earlier version of this skill carried ~19 symbol names that had not existed since
the OCaml compiler was deleted. Verify, don't assume, including the names below.)

## Two invariants you must not break

- **Errors accumulate; phases don't exit on first failure.** They push into
  `compiler/driver/diagnostics.mdk`. Inside the typechecker errors are plain
  `String` messages pushed via the `pushTypeError*` family (see below) — there is
  no `TypeError` ADT and no `fail`/`raise` path. Don't add early exit/panic paths,
  and don't short-circuit a later phase because an earlier one failed.
- **Level bracketing must be exception-safe.** Generalization uses Rémy levels:
  hand-balanced `enterLevel ()` / `exitLevel ()` (`tc_unify.mdk`)
  pairs around the `currentLevel` cell (`ModuleCells`, `tc_types.mdk`). A non-local exit *between* them permanently
  increments the level. Each module check mints a fresh `ModuleCtx` (`freshModuleCtx`)
  on entry, so a leak is wiped before the next run; and within a single run the
  leak is *relative* — `processSCC` (`tc_module.mdk`) brackets against whatever base it
  starts at and generalizes against that same base, so a uniform leak does not by
  itself break generalization. Still: if you add a path that can exit mid-bracket,
  restore the level at the boundary.

## Can't-happen vs. recoverable: `panic` vs. `pushTypeError`

A genuinely impossible invariant violation uses `panic "context"`
(e.g. `panic "unify: tuple arity mismatch"`). Native `panic` is **unrecoverable by
design** (see the `no-catchable-panics-isolation` decision) — reserve it for true
impossibilities, and **don't `panic` on anything a user program can actually
reach.** A *recoverable* condition a real program can trigger — notably a
cross-module lookup that can miss — must `pushTypeError` a clear user-facing
message rather than panic. **Exception:** a *rendering* path must never panic —
`ppMono` (`repr.mdk`) returns the placeholder `"_"` for a post-normalize `Link`
rather than crashing, because it runs while formatting an error message.

## Generalization is value-restricted (Phase 66)

`let`/`do`-`let` bindings are only generalized when their RHS is a **syntactic
value**. The gate is `isNonexpansive` (`tc_groups.mdk`) — literal / var / lambda; tuple or
list-literal of values; `ELoc`/`EAnnot` transparent — *everything else, including
all applications, is expansive*. Generalization goes through
`genBindingRestricted isValue t` (`tc_groups.mdk`), not bare `generalize` (`tc_unify.mdk`), at every
binding site.

The non-obvious rule if you touch any of this: **a non-generalized binding must
have its free vars *lowered* to `currentLevel`, not merely wrapped in a
monotype.** Otherwise the vars sit at a deeper level and an *enclosing* `let`'s
`generalize` picks them up — reopening the unsoundness one scope out.
`genBindingRestricted` does this via `lowerToCurrent` (`tc_unify.mdk`); the non-`PVar` pattern
path gets it for free because `unify` lowers through `occursAdjust`
(both `tc_unify.mdk`). Note `Ref` is a *constructor* (`extern Ref : a -> Ref a`), so — like
SML/OCaml's `ref` — constructor applications are deliberately expansive.

## Adding a type error

**Every new diagnostic needs a stable code.** `pushTypeError` takes the code as
its *first* argument. Before you write the message:

- register the new code in **`compiler/DIAGNOSTIC-CODES-DESIGN.md`** (typechecker
  codes are the `T-*` family), and
- write the message against **`compiler/ERROR-QUALITY.md`** (the rubric: located,
  names the rule, actionable fix, carries a code).

The real API (`compiler/types/tc_diag.mdk`):

```
pushTypeError          : ModuleCtx -> DiagCode -> String -> Unit
pushTypeErrorAt        : ModuleCtx -> DiagCode -> Option Loc -> String -> Unit
pushTypeErrorOnce      : ModuleCtx -> DiagCode -> String -> Unit                    -- dedups
pushTypeErrorOnceAt    : ModuleCtx -> DiagCode -> Option Loc -> String -> Unit      -- dedups
pushTypeErrorHelpFixAt : ModuleCtx -> DiagCode -> Option Loc -> String -> String -> Option (Loc, String) -> Unit
```

Real call sites read `pushTypeErrorAt mctx TEffectLeak loc msg` (`tc_effects.mdk`)
and `pushTypeErrorAt mctx TConflictingImpl loc msg` (`tc_global.mdk`).

- **`pushTypeError` does NOT dedup** — it plain-conses. `pushTypeErrorOnce` is the
  deduping variant.
- **`pushTypeError` captures `mctx.mcLoc` itself**, the span of the innermost
  construct around the push (a construct hands its sub-walk a copy with its own
  span, `mctxAt`/`envAt`). That is right *during* the `infer` walk, but a post-HM
  pass runs outside every construct and holds no span. If your error fires from a deferred/post-HM pass,
  capture the loc at *record* time into the obligation tuple (that is why
  the call and impl obligation records both
  carry an `Option Loc`; their cells are listed in `compiler/types/CELL-LIFETIMES.md`) and raise with `pushTypeErrorOnceAt` / `pushTypeErrorHelpFixAt`.
- Use `pushTypeErrorHelpFixAt` when you can offer a machine-applicable fix — it is
  what surfaces `help` + `fix` in `medaka check --json`.

The mechanical loop:

1. **Message builder** — write (or reuse) a `…Msg : … -> String` helper that formats
   the message from the names + `Mono`s involved. Real examples: `effectLeakMsg`
   (`tc_unify.mdk`), `effectParamMsg` (`effect_param_decode.mdk`), `ambiguousImplMsg` (`tc_diag_text.mdk`; the
   context-free message builders live there). Grep for an
   existing `Msg` builder near the error family you're adding and mirror it.
   **When a message names two or more types**, render them through one shared
   naming context — `ppMonosShared : List Mono -> <Mut> String` (`repr.mdk`) — not
   separate `ppMono` calls, or two distinct tyvars can both print as `a`.
   (`ppMono` / `ppScheme`, `repr.mdk`, render a single type/scheme.)
2. **Raise site** — `pushTypeError mctx TYourCode (yourMsg …)` from the phase that
   detects it. The new code is a constructor of `DiagCode` (`support/diag_codes.mdk`: the
   type, `codeText`, `allDiagCodes`) plus a `live` row in the registry of `compiler/DIAGNOSTIC-CODES-DESIGN.md`.
3. **Test** — add a fixture to `test/diff_compiler_check_test.mdk`'s corpus.
   **Watch for prelude name collisions:** a fixture that reuses a stdlib interface
   name (e.g. `Monoid`) may pass on a *duplicate-interface* error rather than the
   error you intend — use a fresh name so the test exercises what it claims.
4. **Check the JSON shape** — `./medaka check --json scratch.mdk` and confirm your
   `code`, `range`, `severity`, and (if any) `help`/`fix` come out right.

> A structured error ADT (to replace the string messages) is a *parked* future
> refactor — see PLAN.md. Until then, string + per-error builder is the idiom; do
> **not** introduce a `TypeError` ADT as part of an unrelated change.

## Where things live

Owners below are the `compiler/types/` modules, verified by grep at the time of writing; the
layer table is `compiler/ARCHITECTURE-PLAYBOOK.md` §6 and each module's spec is in `compiler/types/ARCHITECTURE.md`. Grep the name.

| Area | Real names |
|---|---|
| Unification / generalization | `tc_unify.mdk`: `unify`, `generalize`, `instantiate`, `freshVar`, `enterLevel`/`exitLevel`, `lowerToCurrent`, `occursAdjust`; `repr.mdk`: `normalize`; `tc_state.mdk`: `freshModuleCtx` |
| Value restriction | `tc_groups.mdk`: `isNonexpansive`, `genBindingRestricted`; `tc_unify.mdk`: `lowerToCurrent`, `occursAdjust` |
| Errors / rendering | `tc_diag.mdk`: `pushTypeError`, `pushTypeErrorOnce`, `pushTypeErrorOnceAt`, `pushTypeErrorHelpFixAt`; `tc_state.mdk`: `mctxAt`; `repr.mdk`: `ppMono`, `ppScheme`, `ppMonosShared`; `tc_diag_text.mdk`: the context-free message builders |
| Group inference (letrec/SCC) | `tc_module.mdk`: `processSCCs` → `processSCC`; `tc_groups.mdk`: `sccSchemes`, `isLetrecGroup` |
| Constraint obligations | `tc_occurrence.mdk`: `recordCallObligations`, `recordImplObligation`; `tc_unify.mdk`: `recordSchemeCallObligations`; `schemeObligationsRef` is a `ModuleCells` cell. `allConcreteHeads` (`tc_mono.mdk`) is the is-it-ground test the obligation checkers gate on (`checkCallObligationsU`, `checkReqOne` in `tc_solve_check.mdk`). |
| Interfaces / supers | `tc_scope.mdk`: `methodEntryHere`; `tc_unify.mdk`: `lookupQualPayload`; `tc_solve_check.mdk`: `ifaceSelfAndSupers`; the one closure combinator `superClosure`/`directSupers` (`compiler/types/superclass.mdk`). A dictionary carries its direct supers (DICT §2): an instance's supers are solved at its construction goal (`directSuperGoals`, `superRoutesAt`, `tc_solve_entail.mdk`), and a given's super is a projection (`RProj`, `assumAnswerRoute` in `tc_solve_givens.mdk`), never selected again |
| Impls | `ImplRow` (the impl-table row, `tc_types.mdk`), `ieSelectRowByIface` (the interface-keyed row selector, `tc_solve_entail.mdk`) |
| Coherence | All in `tc_global.mdk` except `cohOverlap` (`tc_mono.mdk`): `checkCoherence` → `cohRowsOwnedBy` → `cohImplOfRow` → `cohScan` → `cohOverlap` (bidirectional unification: two impls overlap iff their head-type lists unify under one substitution). The input is a projection of stage K's `IE` rows, not a decl walk, and the interface half is compared by identity via `cohSameIface` = `sameTyConHead`, **never** `ifaceIdMatches`, which is its exact inverse and would turn every unstamped-origin conflict into a silent accept. **Program impls are paired with the prelude's impls** (ordinal 0 on the Module arm; `cohPreludeRows`), so a program impl α-equal to a prelude impl is a hard `T-CONFLICTING-IMPL` at the program's impl (DICT §6.1 point 5); prelude-vs-prelude pairs are never reported, and the whole-graph sweep (`cohRowsOf`) leaves the prelude to the per-module sweep. The sweep is CLASSIFIED, not single-verdict: `cohClassify` splits an overlapping non-ranked pair into a HARD `T-CONFLICTING-IMPL` (mutually ⊑ / α-equal heads, a DICT §6 C1 violation nothing downstream catches) and a SOFT `W-INCOMPARABLE-IMPLS` warning (⊑-incomparable heads, condition (a) alone, whose acceptance is per-goal and belongs to `pickMostSpecificEntry` in `tc_solve_entail.mdk`). `cohScan` therefore returns ONE OF EACH class rather than the first conflict: reporting only the first would let a soft pair hide a hard one. |
| Data / record / alias registration | `tc_decls.mdk`: `registerData`, `registerVariants`, `registerRecordInfoKeyed`, `buildAliasGraphEntry`, `rejectCyclicAliases`; `tc_decls_types.mdk`: `fromAstType`; `aliasTableRef` is a `ModuleCells` cell |
| The entry and the verbs | `typecheck.mdk`: `checkOneDiags`, `checkOneSchemeFullK`, `driveGraphK`, `checkModules`, `elaborateModules` |

**`fromAstType` gotcha.** Its signature is
`fromAstType : List (String, Mono) -> Ty -> <Mut> Mono` (`tc_decls_types.mdk`) — the tvar table
is an **ordinary first positional argument** (`tvs`). (Medaka has **no labeled
arguments**.) Call it with a fresh `[]` and the same source name `a` in two separate
calls becomes two unrelated TVars. When two `Ty` values must share variables (impl
head ↔ `requires`, signature ↔ its constraints), **thread one `tvs` list through
both calls.**

## Whole-program routes — audit both

Per-node `infer`/`check` arms are shared, and both routes funnel group inference
through `processSCCs`/`processSCC` (`tc_module.mdk`). Trace registration order, coherence, and the
final passes through both routes:

- one-program: `checkOneDiags`, with `checkOneSchemeFullK` for scheme queries — locate
  them with `grep -n '^checkOneDiags \|^checkOneSchemeFullK ' compiler/types/typecheck.mdk`
  (line numbers in this file rot; derive them)
- multi-module: `checkModuleFullDiags` (`tc_module.mdk`), driven by the one graph driver `driveGraphK`
  (`GOutDiags` for diagnostics and schemes, `GOutTrees` for the elaborated tree that
  `elaborateModules` projects) / `checkModules` for the schemes-only fast path

Both routes reach `checkCoherence` / `checkPhantomMethods` / `checkSuperImpls` (`tc_global.mdk`) and
`checkInterfaceCycles` (`tc_module.mdk`). **A new whole-program pass that one route skips is silently absent
from part of the compiler** — and real projects use the module graph path.

## Writing tests: a parameter's type is a free var during body inference

A type signature does **not** pre-ground a function's parameter types before the
body is inferred. `processSCC` infers the body with each param as a fresh TVar and
unifies against the declared type *afterwards*. So a body expression that branches
on the *concrete* type of a parameter sees a free var, not the annotated type. To
exercise a type-directed branch, ground the value at the expression itself
(`[1,2,3].[1..2]`, `"abc".[0..1]`), not via a parameter annotation.

## Verify

`main` is protected — work on a branch and land via PR. Before you push:

```sh
medaka fmt --write <abs path of each touched compiler/types/*.mdk>   # pre-commit hook REJECTS unformatted .mdk
medaka lint <same paths>                                              # hook is a max ratchet: any new finding fails
make preflight                                    # derives the gate set from your diff
```

While iterating, `make check-self` (issue #833) is the sub-minute inner loop: it
runs the already-built `./medaka check` over the `medaka_cli.mdk` closure alone —
no oracle build, no differential compare, gated on that one exit code (~20s).
It is NOT a substitute for the gate below — it's the fast pre-check to run
*before* it, on every edit.

Then the gates that matter for this file specifically:

```sh
bash test/typecheck_compiler_source.sh     # ← DO NOT SKIP. The build does NOT gate on type
                                           #   errors: an ill-typed compiler passes all 83 gates.
                                           #   This is what the required `soundness` CI check runs.
bash test/diff_compiler_check_test.mdk           # typecheck gate (fixtures)
bash test/diff_compiler_check_test.mdk   # multi-module typecheck
bash test/diff_compiler_check_test.mdk
bash test/diff_compiler_eval.sh            # the typechecker loads the real stdlib — a
                                           #   too-broad new rule that rejects valid stdlib
                                           #   code breaks many gates at once
```

If a change rejects something the stdlib relies on, the prelude fails to load and
many gates break at once — that's the signal your rule is too broad. The usual
culprit is feeding a new global impl check the *seeded* impls instead of the
module's own impl rows (`cohRowsOwnedBy` in `compiler/types/tc_global.mdk`).

**The compiler's own source is in the snapshot corpus**, so a change to
a `compiler/types/*.mdk` file moves its own golden — bless it (by naming the path) in the same
commit, or `main` goes red.

## Diagnosing before fixing

If you're not yet sure which stage or construct is at fault, use the
**debug-pipeline** skill. For raw type dumps, run the typecheck probe entry
(`compiler/entries/typecheck_main.mdk`) — check its `main` for the exact
invocation form. For structured output, `./medaka check --json scratch.mdk`.

Bare `./medaka check` now filters the scheme dump down to the user's own
top-level bindings (0.1.0 UX — the prelude corpus used to print first and
swamp it). When you need to see what a **prelude** method itself infers to
(e.g. debugging `pure`/`when`), pass `--types` to restore the full dump
including seeded schemes.
