---
name: harden-typechecker
description: Typechecker-internal correctness and diagnostics work in compiler/types/typecheck.mdk — add or refine a type_error, tighten constraint/coherence/unification logic, or fix an over/under-generalization bug. Use for the PLAN-ARCHIVE.md Phase 62–72 hardening arc, or whenever the fix lives inside the type checker rather than threading new surface syntax.
---

# Harden the typechecker

Almost everything here happens in one file, `compiler/types/typecheck.mdk`. The
work is narrower than `add-language-feature` (no lexer/parser/AST changes): you
are making the checker *reject more*, *diagnose better*, or *generalize
correctly*, without disturbing the two invariants below.

Read the relevant PLAN-ARCHIVE.md phase first — each entry has a **Where.**
section with approximate locations and a **Done when.** acceptance test. Those
locations drift; confirm with search before trusting them.

## Two invariants you must not break

- **Errors accumulate; phases don't exit on first failure.** They push into
  `compiler/driver/diagnostics.mdk`. Inside `typecheck.mdk` the idiom is
  `pushTypeError (someMsg …)` — it dedups and appends the `String` message to the
  accumulator (there is no `fail`/`raise` ADT path; that was the removed OCaml
  compiler). Don't add early exit/panic paths, and don't short-circuit a later
  phase because an earlier one failed.
- **Level bracketing must be exception-safe.** Generalization uses Rémy levels:
  hand-balanced `enterLevel ()` / `exitLevel ()` pairs. A non-local exit *between*
  them permanently increments `currentLevel`. **Nuance confirmed in Phase 71:** the
  whole-program entry points (`checkProgram`, `typecheckModule`) call
  `resetState` on entry, so a leak there is wiped before the next run; and
  within a single run the leak is *relative* — each `processLetrecGroup`
  brackets against whatever base it starts at and generalizes against that same
  base, so a uniform leak does **not** by itself break generalization. The real
  exposure is the **REPL**, which reuses typechecker state: a leak there violates
  the absolute "top-level names pre-bound at level 1" invariant (§2.9). Phase
  71's fix: `checkReplDecl` resets `currentLevel := 0` at each input boundary.
  Still: if you add a path that can `fail` mid-bracket, prefer restoring the
  level (a finally, or reset at the boundary).

## Can't-happen vs. recoverable: `panic` vs. `pushTypeError`

A genuinely impossible invariant violation uses `panic "context"`
(e.g. `panic "unify: tuple arity mismatch"`, `panic ("unbound method: " ++ name)`).
Native `panic` is **unrecoverable by design** (see the `no-catchable-panics-isolation`
decision) — so reserve it for true impossibilities, and **don't `panic` on anything a
user program can actually reach.** A *recoverable* condition a real program can trigger —
notably a cross-module lookup that can miss (`env.interfaces`, `env.records`) — must
`pushTypeError` a clear user-facing message (unknown-interface / unknown-record wording)
rather than panic or let a raw not-found escape. **Exception:** a *rendering* path must
never panic — `ppMono`'s post-normalize `Link` case returns the placeholder `"_"` rather
than crashing, because it runs while formatting an error message.

## Generalization is value-restricted (Phase 66)

`let`/`do`-`let` bindings are only generalized when their RHS is a **syntactic
value**. The gate is `isNonexpansive` (literal / var / lambda; tuple or
list-literal of values; `ELoc`/`EAnnot` transparent — *everything else,
including all applications, is expansive*). Generalization goes through
`genRestricted isValue t` (not bare `generalize`) at every binding site: `ELet`
`PVar`, `DoLet` in `EBlock`/`EDo`, per-binding in `ELetGroup`, and the
top-level non-letrec path in `processLetrecGroup`.

The non-obvious rule if you touch any of this: **a non-generalized binding must
have its free vars *lowered* to `currentLevel`, not merely wrapped in
`monotype`.** Otherwise the vars sit at a deeper level and an *enclosing* `let`'s
`generalize` picks them up — reopening the unsoundness one scope out.
`genRestricted` does this via `lowerToCurrent`; the non-`PVar` pattern path
gets it for free because `unify tp t1` lowers through `occursAdjust`. Note
`Ref` is a *constructor* (`extern Ref : a -> Ref a`), so — like SML/OCaml's
`ref` — constructor applications are deliberately expansive.

## Adding a `type_error`

**Errors are plain `String` messages, not an ADT.** The native compiler has **no
`TypeError`/`ppError` ADT** — that was the removed OCaml `lib/typecheck.ml`. The
native idiom is `pushTypeError : String -> <Mut> Unit` (it dedups, then pushes
into the accumulator), with each error's wording produced by a small per-error
**message-builder function** (`ambiguousImplMsg`, `effectParamMsg`,
`effectLeakMsg`, …) that returns the `String`. So "add a type_error" =
build the message + push it, not "add a variant + a printer case".

The mechanical loop — all in `compiler/types/typecheck.mdk` unless noted:

1. **Message builder** — write (or reuse) a `…Msg : … -> String` helper that
   formats the message from the names + `Mono`s involved. Grep for an existing
   `Msg` builder near the error family you're adding and mirror it. Phrase it as
   *what's wrong + how to fix*. **When a message names two or more types** (a
   mismatch, two impl-head arg lists), render them through one shared naming
   context — `ppMonoPair a b` / `ppMonos args` / `ppMonosPair a b` (Phase 70) —
   not separate `ppMono` calls, or two distinct tyvars can both print as `a`.
   (`ppMono`/`ppScheme` render a single type/scheme.)
2. **Raise site** — `pushTypeError (yourMsg …)` from the phase that detects it
   (or fold the check into an existing selection pass — see below — to cover all
   `typecheck*` entry points at once). `pushTypeError`/`fail` read the global
   `currentLoc`, correct *during* the `infer` walk but **stale in post-HM passes**
   (`checkMethodUsages`, `checkConstraintObligations`, the
   generalization-boundary obligation checks) — by then it points at the last
   expression inferred. If your error fires from a deferred/post-HM pass, capture
   `!currentLoc` into the accumulator/obligation tuple at record time and raise
   with the located form (`failAt loc …` / a `pushTypeError` that threads the
   captured loc) instead (Phase 62 / the 2026-06-26 ambiguous-constraint fix did
   exactly this — follow that pattern).
3. **Test** — add a fixture to the typecheck golden gate or the
   `test/diff_compiler_check.sh` / `_typecheck_errors` suite. Fixtures embed the
   source inline so failures read cleanly. **Watch for prelude name collisions:**
   a fixture that reuses a stdlib interface name (e.g. `Monoid`) may pass on a
   *duplicate-interface* error rather than the error you intend — use a fresh
   name so the test exercises what it claims.

> A structured error ADT (to replace the string messages) is a *parked* future
> refactor motivated by structured LSP diagnostics — see PLAN.md. Until then,
> string + per-error builder is the idiom; do **not** introduce a `TypeError` ADT
> as part of an unrelated change.

## Where things live (grep these names, don't trust line numbers)

- **Unification / generalization** — `unify`, `normalize`, `generalize`,
  `instantiate`, `enterLevel`/`exitLevel`, `freshVar`. Value restriction:
  `isNonexpansive`, `genRestricted`, `lowerToCurrent`.
- **Interfaces & impls** — `registerInterface`, `registerImpl`, `implEntry`,
  `ifaceInfo`. Call-site constraint solving is a family of post-HM passes that
  share `matchingImpls` + `isConcrete` + `failAt loc`:
  `checkMethodUsages`, `checkConstraintObligations`,
  `checkSuperinterfaceObligations` (Phase 64), `checkEntryRequires`
  (Phase 65, recurses for nested `requires`). `monoMatches` is the
  one-directional wildcard match (pattern may have TVars, concrete must be
  ground). Fold a new obligation check *into* the selection passes (rather than
  a new standalone pass) to cover all `typecheck*` entry points at once.
- **Coherence** — `checkCoherence`, `implsOverlap` (bidirectional unification:
  two impls overlap iff their head-type lists unify under one substitution).
  **Seeded (prelude) impls** (`implSeeded`) are excluded from coherence — user
  impls are *meant* to override them (Phase 45.9). Any new global impl check
  must respect that exclusion or it will false-positive on the stdlib itself.
- **Data/record/alias registration** — `registerData`, `registerRecord`,
  `registerAlias`, `expandAliases`, `fromAstType`. **Gotcha:** plain
  `fromAstType` mints a *fresh* TVar table per call, so the same source name
  `a` in two separate calls becomes two unrelated TVars. When two `Ty` values
  must share variables (impl head ↔ `requires`, signature ↔ its constraints),
  thread one table: pass `~tbl` to `fromAstType`, or follow
  `fromAstTypeWithConstraints`, which already shares a `tbl` for exactly this
  reason.

## Writing tests: a parameter's type is a free var during body inference

A type signature does **not** pre-ground a function's parameter types before the
body is inferred. `processLetrecGroup` infers the body with each param as a
fresh TVar and unifies the result against the declared type *afterwards*. So a
body expression that branches on the *concrete* type of a parameter sees a free
var, not the annotated type. To exercise a type-directed branch, ground the
value at the expression itself (`[1,2,3].[1..2]`, `"abc".[0..1]`), not via a
parameter annotation.

## Verify

```sh
make medaka          # rebuild the native compiler
bash test/diff_compiler_check.sh          # typecheck gate (fixtures)
bash test/diff_compiler_check_modules.sh  # multi-module typecheck
```

The typechecker loads the real stdlib, so **also run the suites that exercise
it end-to-end** — a too-aggressive new rule that rejects valid stdlib code shows
up here:

```sh
bash test/diff_compiler_eval.sh
bash test/diff_compiler_check_batch.sh
```

If a change rejects something the stdlib relies on, the prelude fails to load
and many gates break at once — that's the signal your rule is too broad (usual
culprit: not excluding seeded impls, or treating a legitimate named/`default`
impl as a conflict).

## Diagnosing before fixing

If you're not yet sure which stage or construct is at fault, use the
**debug-pipeline** skill. For raw type dumps, run the typecheck probe entry:

```sh
./medaka run compiler/entries/typecheck_main.mdk -- scratch.mdk
```
