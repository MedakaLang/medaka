# META
source_lines=364
stages=DESUGAR,MARK
# SOURCE
-- compiler/driver/main_autoprint.mdk — shared composite-`main` auto-print wrap.
--
-- A bare non-Unit VALUE `main` (`main = ("abc", 1.23)`, `main = [1,2,3]`, a
-- `deriving Display` ADT, …) used to CRASH the emitter (`emitPrint` panics on a
-- non-scalar `main`).  This module implements the uniform fix from
-- compiler/COMPOSITE-MAIN-AUTOPRINT-DESIGN.md §10: rewrite the entry decl
--   main = <e>   ⟶   main = 0autoprintln <e>
-- where `0autoprintln` is the PRELUDE's own `println` declaration re-bound under
-- a name no user program can spell (`autoPrintPinCore`; `display` renders → raw
-- strings, `(a, b)` tuples, `[1, 2, 3]` lists, derived ctors).  See
-- `autoPrintPinCore`'s own comment for why no SPELLING of this call — `println`,
-- or `putStrLn (display …)` — can be safe (#2185, and its F1/F2 recurrence)
-- so the value flows through the ordinary polymorphic print path every
-- backend already compiles.  The wrapped `main : <IO> Unit` suppresses the
-- emitter's own scalar auto-print (installMainIsUnitHint True), so a value is
-- printed exactly ONCE.
--
-- SCOPE / re-mint safety: the wrap fires ONLY on a bare zero-arg non-Unit/non-Async
-- value main.  Every compiler-graph `main` is Unit/`<IO>`-typed, so
-- `shouldAutoPrintMain` is always False on the compiler's own source → the emitter
-- output on the compiler graph is byte-identical → the self-compile fixpoint is
-- stable and NO seed re-mint is owed (design §6).
--
-- UNDERIVED detection: a bare ADT main with no `Display` instance (`data H = H;
-- main = H`) must surface the clean `No impl of Display for H; add 'deriving
-- Display'` error, NOT a miscompile.  `underivedMainDiags` re-runs the CHECK gate
-- (`checkOneDiags`, implInferEnabled OFF → checkImplObligations ON) on the
-- WRAPPED, UN-MANGLED program — exactly what source-level `medaka build` of an
-- explicit `main = println H` already does.  (The design's critical caveat: NEVER
-- call checkImplObligations on the MANGLED emit-elaborated program — it can't match
-- mangled `display`/`println` obligations to impl heads and mis-fires on every
-- program.  Routing through checkOneDiags on un-mangled decls avoids that.)

import frontend.ast.{
  Decl(..),
  Expr(..),
  Pat,
  Loc(..),
  UsePath(..),
  UseMember(..),
}
import types.typecheck.{
  mainTypeIsUnit,
  mainTypeIsAsync,
  checkOneDiagsSynthetic,
  setCoherenceUserDecls,
  TcDiag,
}

-- The loader hands modules dependency-first, so the ENTRY module is last.
entryPair : List (String, List Decl) -> Option (String, List Decl)
entryPair [] = None
entryPair [p] = Some p
entryPair (_ :: rest) = entryPair rest

-- Find the top-level `main`'s param list among a module's decls (skipping @attr
-- wrappers), so the caller can require an EMPTY param list (a value main — a
-- function-shaped `main () =`/`main x =` keeps its own W-MAIN-SHAPE handling and
-- is NEVER auto-printed).
findMainParams : List Decl -> Option (List Pat)
findMainParams [] = None
findMainParams ((DAttrib _ d) :: rest) = findMainParams (d :: rest)
findMainParams ((DFunDef _ "main" ps _) :: _) = Some ps
findMainParams (_ :: rest) = findMainParams rest

-- True iff a top-level `println` binding is in scope (defined by the prelude).
-- The wrap re-binds THAT declaration (`autoPrintPinCore`), so it MUST NOT fire when
-- `println` is undefined — e.g. the emit gates that pass an EMPTY core prelude
-- (test/diff_compiler_llvm_modules.sh) to exercise the emitter's own scalar
-- auto-print.  A real `medaka build` always passes core.mdk (which defines
-- `println x = putStrLn (display x)`), so the wrap fires there.
definesPrintln : List Decl -> Bool
definesPrintln [] = False
definesPrintln ((DAttrib _ d) :: rest) = definesPrintln (d :: rest)
definesPrintln ((DFunDef _ "println" _ _) :: _) = True
definesPrintln (_ :: rest) = definesPrintln rest

-- Auto-print fires iff main's inferred type is neither Unit nor `Async _`, the
-- entry `main` is a zero-arg VALUE (empty param list), AND `println` is in scope.
-- Requires the caller to have run an elaborate first (populates mainSchemeRef).
export
shouldAutoPrintMain : List Decl -> List (String, List Decl) -> Bool
shouldAutoPrintMain coreDecls modules =
  if mainTypeIsUnit () || mainTypeIsAsync () then
    False
  else if not (definesPrintln (coreDecls ++ flatMap snd modules)) then
    False
  else match entryPair modules
    None => False
    Some (_, decls) => match findMainParams decls
      Some [] => True
      _ => False

-- True iff the decl is `main`'s explicit type signature (`main : T`), possibly
-- @attr-wrapped.  When the wrap fires the body becomes `main = 0autoprintln <e>`
-- (: `<IO> Unit`), so a stale explicit `main : <non-Unit>` sig would make the
-- re-check report a `<non-Unit> vs Unit` mismatch → empty IR → build failure.
-- The wrap drops it (the signature was only ever consulted to detect the
-- non-Unit-ness that fires the wrap in the first place).
isMainTypeSig : Decl -> Bool
isMainTypeSig (DAttrib _ d) = isMainTypeSig d
isMainTypeSig (DTypeSig _ "main" _) = True
isMainTypeSig _ = False

-- Rewrite the entry module's `main = <e>` decl to `main = 0autoprintln <e>`, and
-- drop any explicit `main : T` signature (now stale — see isMainTypeSig).
-- ⚠️ The caller MUST pair this with `autoPrintPinCore` on the core decl list.
export
autoPrintWrapModules : List (String, List Decl) -> List (String, List Decl)
autoPrintWrapModules [] = []
autoPrintWrapModules [(mid, decls)] =
  [(mid, map wrapMainDecl (filter (d => not (isMainTypeSig d)) decls))]
autoPrintWrapModules (p :: rest) = p :: autoPrintWrapModules rest

wrapMainDecl : Decl -> Decl
wrapMainDecl (DFunDef vis "main" [] body) =
  DFunDef vis "main" [] (wrapPrintln body)
wrapMainDecl (DAttrib a d) = DAttrib a (wrapMainDecl d)
wrapMainDecl d = d

-- The auto-print wrap's own entry point: an UNSPELLABLE name under which the
-- prelude's own `println` declaration is re-bound (see `autoPrintPinCore`).  A
-- Medaka identifier can never begin with a digit, so no user declaration — top
-- level, interface method, or local — can be spelled this way, which is what
-- makes a reference to it uncapturable rather than merely unlikely to be
-- captured.  (`sanitizeId` is applied to the MODULE id, not the name, so this
-- reaches the backends verbatim as the tail of `mdk_<core>__0autoprintln`;
-- digits are legal there, unlike `#`/`$`.)
export
autoPrintPinName : String
autoPrintPinName = "0autoprintln"

-- Re-bind the PRELUDE's own `println` under `autoPrintPinName`, by COPYING its
-- declarations out of the core decl list the caller already holds.
--
-- 🚨 #2185 / F1 / F2 — WHY A PRELUDE-SIDE RE-BINDING AND NOT A RESPELLING.
-- Slice 1 "fixed" #2185 by respelling the wrap from `EVar "println"` to
-- `EApp (EVar "putStrLn") (EApp (EVar "display") …)`.  Both spellings are bare
-- `EVar`s synthesized INTO THE ENTRY MODULE, and every bare name synthesized
-- there is resolved against the ENTRY MODULE's scope — where a user's own
-- `interface Ifc c where display : c -> String` outranks the prelude's `Display`
-- (`ownMethodIdent`, `overrideScopedMethods` in `compiler/types/typecheck.mdk`:
-- an OWN declaration wins outright).  So the identical S0 simply moved from
-- `println` to `display`, a name users declare constantly, plus an S1 false
-- reject (`No impl of Ifc for Int`) on a program that declares such an
-- interface and never implements it.  There is no safe SPELLING; the wrap has
-- to stop resolving in the user's scope at all.
--
-- MEASURED (the discriminator this fix is built on): a user-written
-- `main = println 7` beside `interface Ifc c where display : c -> String` +
-- `impl Ifc Int` prints `7`, not `HIJACKED` — the prelude's `println` body
-- (`putStrLn (display x)`, stdlib/core.mdk) resolves its `display` in the
-- PRELUDE's scope, where `Display` is the one own declaration and no user
-- interface can outrank it.  Only the synthesized occurrence was ever broken.
--
-- So the wrap now denotes THAT declaration: this copies the prelude's
-- `println : Display a => a -> <IO> Unit` signature and body verbatim under an
-- unspellable name and appends them to the core decl list, and `wrapPrintln`
-- emits `EVar autoPrintPinName`.  The copied body is a PRELUDE decl, so its
-- `display`/`putStrLn` are prelude-scoped exactly as `println`'s own are, and
-- the reference cannot be captured because the name cannot be declared.  No
-- name the wrap synthesizes is resolved in user scope any more — including
-- `putStrLn`, whose (narrower) capture vector goes with it.
--
-- Verbatim copies, not a hand-built AST: the signature carries the constraint
-- that puts the name in `markWith`'s `constrained` set (so the occurrence marks
-- `EDictApp`, precisely as `println`'s own occurrences do) and no second
-- spelling of `Display a => a -> <IO> Unit` is minted that could drift from the
-- prelude's.
--
-- Fires ONLY when the wrap fires (`shouldAutoPrintMain`, which already requires
-- `definesPrintln`), so a program with a Unit/Async/function `main` — the
-- compiler's own graph included — gets an unchanged core decl list and the
-- self-compile fixpoint is untouched.
export
autoPrintPinCore : List Decl -> List Decl
autoPrintPinCore coreDecls = coreDecls ++ pinnedPrintlnDecls coreDecls

pinnedPrintlnDecls : List Decl -> List Decl
pinnedPrintlnDecls decls = pinnedCopies "println" autoPrintPinName decls

-- Copies of every signature and clause of `origin` re-bound under `pin`, marked
-- exported so a synthesized import can reach them.
pinnedCopies : String -> String -> List Decl -> List Decl
pinnedCopies _ _ [] = []
pinnedCopies origin pin ((DAttrib _ d) :: rest) =
  pinnedCopies origin pin (d :: rest)
pinnedCopies origin pin ((DTypeSig _ n ty) :: rest) =
  if n == origin then
    DTypeSig True pin ty :: pinnedCopies origin pin rest
  else
    pinnedCopies origin pin rest
pinnedCopies origin pin ((DFunDef _ n ps body) :: rest) =
  if n == origin then
    DFunDef True pin ps body :: pinnedCopies origin pin rest
  else
    pinnedCopies origin pin rest
pinnedCopies origin pin (_ :: rest) = pinnedCopies origin pin rest

-- `main = <e>` → `main = 0autoprintln <e>`, re-attaching the body's own source
-- span (its outer `ELoc`, from `parseLocated`) around the synthetic application
-- so the auto-print Display obligation reports AT the main body — not at
-- `{0,0}` — on the check/LSP path (underivedMainDiags).  `ELoc` is transparent
-- to every backend, so the emitted IR is unchanged.  An un-located body (plain
-- `parse`) wraps bare.
--
-- The callee is the prelude's own `println` declaration re-bound under an
-- unspellable name — see `autoPrintPinCore` above for why no SPELLING of this
-- call (`println`, or `putStrLn (display …)`) can be safe.  Every caller that
-- calls `autoPrintWrapModules` MUST also pass `autoPrintPinCore coreDecls` as
-- the core decl list, or the name is unbound.
wrapPrintln : Expr -> Expr
wrapPrintln body = wrapCall autoPrintPinName body

-- `<e>` → `callee <e>`, keeping the body's outer `ELoc` around the application.
wrapCall : String -> Expr -> Expr
wrapCall callee (ELoc l inner) = ELoc l (EApp (EVar callee) (ELoc l inner))
wrapCall callee body = EApp (EVar callee) body

-- Re-run the CHECK gate on the wrapped program to surface an underived-ADT main
-- as the clean `No impl of Display …` type error.  Gated to a SINGLE loaded
-- module (the common composite-main shape: playground + `medaka build file.mdk`):
-- `checkOneDiags` runs the ONE-MODULE `Module` arm over just this module, keyed by
-- the module id the caller already bound.  A multi-module program flattened this way
-- risks the over-rejection the CLI's multi-module gate deliberately avoids, so it is
-- skipped there (best-effort — the compiler graph never wraps, so this never affects
-- the fixpoint).  Returns the type-error `TcDiag`s for the caller to render.
--
-- ⚠️ THIS CALL WAS PINNED TO THE `Flat` ARM (#2049) AND THE PIN IS NOW DISCHARGED —
-- do not re-derive the S0 from this comment, it describes a FIXED defect.
-- S-migrate-check-route (E-1 #1115) first pointed this at `checkOneDiags` and that was
-- an S0: this is not an ordinary `check` front door, it is a re-check run BETWEEN the
-- two emit elaborations of `runEmitWith` (`entries/entry_support.mdk`), so whatever
-- global state it leaves behind is read by the emit elaboration that follows it.  On
-- `medaka build` of
--
--     data A = A { p : Int, k : Int }
--     main =
--       let a = A { p = 10, k = 5 }
--       a.k
--
-- the `Module` arm produced `@mdk_core__println(i64 0, %t)` (SIGSEGV 139) where the
-- `Flat` arm produced `@mdk_core__println(ptr @mdk_dc_0, %t)` (prints `5`), IR
-- otherwise byte-identical.
--
-- THE LEAKED REF IS `driverState.matchOracle`, isolated by S-emit-interleave-leak:
-- `elaborateModules` never seeded it, so the emit elaboration read this re-check's
-- residue; the `Module` arm writes identity-keyed (`TkIdent`) rows under the ENTRY
-- MODULE'S OWN id — exactly the key the emit driver's `oGetCtors` readers mint — while
-- the `Flat` arm's rows are `TkBare` and always missed.  The hit is against rows built
-- from the UN-MANGLED tree, so `ctorSiblingWithholdingName` false-rejected `a.k`
-- (`Field 'k' is not declared by every constructor of 'A'`), `Display` could not ground,
-- and the emitter wrote a null dict word — silently, since the emit driver discards
-- `hadTypeErrors`.  The DISCRIMINATOR was the module id, not the arm: passing a rootId
-- other than `mid` (`"__user__"`, any constant) made the same `Module`-arm call emit
-- byte-identical IR, because the stale rows then keyed somewhere the reader never looks.
-- Fixed at the seam, not here: `elaborateModules` now mints its own empty oracle, so no
-- interleaved check of any arm can reach its readers.  See that line in
-- `compiler/types/typecheck.mdk` for the full mechanism and for why seeding a CORRECT
-- oracle there is a separate, larger change.
export
underivedMainDiags : List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List TcDiag
underivedMainDiags runtimeDecls coreDecls [(mid, entryDecls)] =
  let _ = setCoherenceUserDecls entryDecls
  -- `entryDecls` here is the WRAPPED program (`main = println <e>`), not the user's,
  -- so this re-check must not be allowed to redefine the driver's record of the real
  -- `main`'s type — `checkOneDiagsSynthetic` (types/typecheck.mdk) is `checkOneDiags`
  -- with `mainSchemeRef` saved and restored around it, and its header states the
  -- `W-MAIN-SHAPE` regression that reaching for the plain one reintroduces.
  let (tcErrs, _) =
    checkOneDiagsSynthetic runtimeDecls coreDecls (mid, entryDecls)
  tcErrs
underivedMainDiags _ _ _ = []

-- ── `main : Async _` driver wrap (ASYNC-DESIGN D5, ASYNC-RUNTIME-DESIGN §4.4) ──
-- A `main` whose type heads in `Async` is an inert VALUE until a driver forces
-- it, so forcing it alone runs nothing (#2506).  Every engine drives it through
-- the same rewrite the auto-print wrap uses:
--   main = <e>   ⟶   main = 0runasync <e>
-- where `0runasync` is the `async` module's own entry driver (`runAsyncIOMain`,
-- or `runAsyncMain` on a target with no clock; each declares a `Unit` result so
-- no backend auto-prints it) re-bound under an unspellable name and
-- imported into the entry module by a synthesized `import async.{0runasync}`.
-- The pinned copy is a DECLARATION OF THE ASYNC MODULE, so its body resolves
-- in that module's scope and no user name can capture the reference — the
-- same argument `autoPrintPinCore` makes for `println`.  The driver's own row
-- is applied here, not in user source, so a program's manifest still lists
-- only what the program performs.
export
asyncMainPinName : String
asyncMainPinName = "0runasync"

asyncModuleId : String
asyncModuleId = "async"

-- Fires iff main's inferred type heads in `Async`, the entry `main` is a
-- zero-arg VALUE, and the `async` module is loaded and defines `driver`.
-- Requires the caller to have run an elaborate first (populates mainSchemeRef).
export
shouldAsyncWrapMain : String -> List (String, List Decl) -> Bool
shouldAsyncWrapMain driver modules =
  if not (mainTypeIsAsync ()) then
    False
  else match entryPair modules
    None => False
    Some (_, decls) => match findMainParams decls
      Some [] =>
        any (p => fst p == asyncModuleId && definesFun driver (snd p)) modules
      _ => False

definesFun : String -> List Decl -> Bool
definesFun _ [] = False
definesFun n ((DAttrib _ d) :: rest) = definesFun n (d :: rest)
definesFun n ((DFunDef _ m _ _) :: rest) =
  if m == n then True else definesFun n rest
definesFun n (_ :: rest) = definesFun n rest

-- Pin `driver` in the `async` module under `asyncMainPinName`, import the pin
-- into the entry module, and rewrite `main = <e>` to `main = 0runasync <e>`.
-- The entry's `main : T` signature is dropped: the wrapped main's type is the
-- driver's result, not `Async`.
export
asyncWrapModules : String ->
  List (String, List Decl) ->
  List (String, List Decl)
asyncWrapModules driver modules =
  wrapAsyncEntry (map (pinAsyncDriver driver) modules)

pinAsyncDriver : String -> (String, List Decl) -> (String, List Decl)
pinAsyncDriver driver (mid, decls) =
  if mid == asyncModuleId then
    (mid, decls ++ pinnedCopies driver asyncMainPinName decls)
  else
    (mid, decls)

wrapAsyncEntry : List (String, List Decl) -> List (String, List Decl)
wrapAsyncEntry [] = []
wrapAsyncEntry [(mid, decls)] = [
  (
    mid,
    asyncPinImport
      :: map wrapAsyncMainDecl (filter (d => not (isMainTypeSig d)) decls),
  ),
]
wrapAsyncEntry (p :: rest) = p :: wrapAsyncEntry rest

synthLoc : Loc
synthLoc = Loc "" 0 0 0 0

asyncPinImport : Decl
asyncPinImport =
  DUse
    False
    (UseGroup [asyncModuleId] [UseMember asyncMainPinName False synthLoc None])
    synthLoc

wrapAsyncMainDecl : Decl -> Decl
wrapAsyncMainDecl (DFunDef vis "main" [] body) =
  DFunDef vis "main" [] (wrapCall asyncMainPinName body)
wrapAsyncMainDecl (DAttrib a d) = DAttrib a (wrapAsyncMainDecl d)
wrapAsyncMainDecl d = d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" false) (mem "Loc" true) (mem "UsePath" true) (mem "UseMember" true))))
(DUse false (UseGroup ("types" "typecheck") ((mem "mainTypeIsUnit" false) (mem "mainTypeIsAsync" false) (mem "checkOneDiagsSynthetic" false) (mem "setCoherenceUserDecls" false) (mem "TcDiag" false))))
(DTypeSig false "entryPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "entryPair" ((PList)) (EVar "None"))
(DFunDef false "entryPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "entryPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "entryPair") (EVar "rest")))
(DTypeSig false "findMainParams" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "findMainParams" ((PList)) (EVar "None"))
(DFunDef false "findMainParams" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "findMainParams") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findMainParams" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PVar "ps") PWild) PWild)) (EApp (EVar "Some") (EVar "ps")))
(DFunDef false "findMainParams" ((PCons PWild (PVar "rest"))) (EApp (EVar "findMainParams") (EVar "rest")))
(DTypeSig false "definesPrintln" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "definesPrintln" ((PList)) (EVar "False"))
(DFunDef false "definesPrintln" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "definesPrintln") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definesPrintln" ((PCons (PCon "DFunDef" PWild (PLit (LString "println")) PWild PWild) PWild)) (EVar "True"))
(DFunDef false "definesPrintln" ((PCons PWild (PVar "rest"))) (EApp (EVar "definesPrintln") (EVar "rest")))
(DTypeSig true "shouldAutoPrintMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool"))))
(DFunDef false "shouldAutoPrintMain" ((PVar "coreDecls") (PVar "modules")) (EIf (EBinOp "||" (EApp (EVar "mainTypeIsUnit") (ELit LUnit)) (EApp (EVar "mainTypeIsAsync") (ELit LUnit))) (EVar "False") (EIf (EApp (EVar "not") (EApp (EVar "definesPrintln") (EBinOp "++" (EVar "coreDecls") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))))) (EVar "False") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EVar "True")) (arm PWild () (EVar "False"))))))))
(DTypeSig false "isMainTypeSig" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isMainTypeSig" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isMainTypeSig") (EVar "d")))
(DFunDef false "isMainTypeSig" ((PCon "DTypeSig" PWild (PLit (LString "main")) PWild)) (EVar "True"))
(DFunDef false "isMainTypeSig" (PWild) (EVar "False"))
(DTypeSig true "autoPrintWrapModules" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "autoPrintWrapModules" ((PList)) (EListLit))
(DFunDef false "autoPrintWrapModules" ((PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EApp (EApp (EVar "map") (EVar "wrapMainDecl")) (EApp (EApp (EVar "filter") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isMainTypeSig") (EVar "d"))))) (EVar "decls"))))))
(DFunDef false "autoPrintWrapModules" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "autoPrintWrapModules") (EVar "rest"))))
(DTypeSig false "wrapMainDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "wrapMainDecl" ((PCon "DFunDef" (PVar "vis") (PLit (LString "main")) (PList) (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (ELit (LString "main"))) (EListLit)) (EApp (EVar "wrapPrintln") (EVar "body"))))
(DFunDef false "wrapMainDecl" ((PCon "DAttrib" (PVar "a") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "a")) (EApp (EVar "wrapMainDecl") (EVar "d"))))
(DFunDef false "wrapMainDecl" ((PVar "d")) (EVar "d"))
(DTypeSig true "autoPrintPinName" (TyCon "String"))
(DFunDef false "autoPrintPinName" () (ELit (LString "0autoprintln")))
(DTypeSig true "autoPrintPinCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "autoPrintPinCore" ((PVar "coreDecls")) (EBinOp "++" (EVar "coreDecls") (EApp (EVar "pinnedPrintlnDecls") (EVar "coreDecls"))))
(DTypeSig false "pinnedPrintlnDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "pinnedPrintlnDecls" ((PVar "decls")) (EApp (EApp (EApp (EVar "pinnedCopies") (ELit (LString "println"))) (EVar "autoPrintPinName")) (EVar "decls")))
(DTypeSig false "pinnedCopies" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "pinnedCopies" (PWild PWild (PList)) (EListLit))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DTypeSig" PWild (PVar "n") (PVar "ty")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EVar "DTypeSig") (EVar "True")) (EVar "pin")) (EVar "ty")) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "True")) (EVar "pin")) (EVar "ps")) (EVar "body")) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest")))
(DTypeSig false "wrapPrintln" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "wrapPrintln" ((PVar "body")) (EApp (EApp (EVar "wrapCall") (EVar "autoPrintPinName")) (EVar "body")))
(DTypeSig false "wrapCall" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "wrapCall" ((PVar "callee") (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "callee"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "inner")))))
(DFunDef false "wrapCall" ((PVar "callee") (PVar "body")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "callee"))) (EVar "body")))
(DTypeSig true "underivedMainDiags" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "TcDiag"))))))
(DFunDef false "underivedMainDiags" ((PVar "runtimeDecls") (PVar "coreDecls") (PList (PTuple (PVar "mid") (PVar "entryDecls")))) (EBlock (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "entryDecls"))) (DoLet false false (PTuple (PVar "tcErrs") PWild) (EApp (EApp (EApp (EVar "checkOneDiagsSynthetic") (EVar "runtimeDecls")) (EVar "coreDecls")) (ETuple (EVar "mid") (EVar "entryDecls")))) (DoExpr (EVar "tcErrs"))))
(DFunDef false "underivedMainDiags" (PWild PWild PWild) (EListLit))
(DTypeSig true "asyncMainPinName" (TyCon "String"))
(DFunDef false "asyncMainPinName" () (ELit (LString "0runasync")))
(DTypeSig false "asyncModuleId" (TyCon "String"))
(DFunDef false "asyncModuleId" () (ELit (LString "async")))
(DTypeSig true "shouldAsyncWrapMain" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool"))))
(DFunDef false "shouldAsyncWrapMain" ((PVar "driver") (PVar "modules")) (EIf (EApp (EVar "not") (EApp (EVar "mainTypeIsAsync") (ELit LUnit))) (EVar "False") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EApp (EApp (EVar "any") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EVar "asyncModuleId")) (EApp (EApp (EVar "definesFun") (EVar "driver")) (EApp (EVar "snd") (EVar "p")))))) (EVar "modules"))) (arm PWild () (EVar "False")))))))
(DTypeSig false "definesFun" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "definesFun" (PWild (PList)) (EVar "False"))
(DFunDef false "definesFun" ((PVar "n") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "definesFun") (EVar "n")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definesFun" ((PVar "n") (PCons (PCon "DFunDef" PWild (PVar "m") PWild PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EVar "True") (EApp (EApp (EVar "definesFun") (EVar "n")) (EVar "rest"))))
(DFunDef false "definesFun" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "definesFun") (EVar "n")) (EVar "rest")))
(DTypeSig true "asyncWrapModules" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "asyncWrapModules" ((PVar "driver") (PVar "modules")) (EApp (EVar "wrapAsyncEntry") (EApp (EApp (EVar "map") (EApp (EVar "pinAsyncDriver") (EVar "driver"))) (EVar "modules"))))
(DTypeSig false "pinAsyncDriver" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "pinAsyncDriver" ((PVar "driver") (PTuple (PVar "mid") (PVar "decls"))) (EIf (EBinOp "==" (EVar "mid") (EVar "asyncModuleId")) (ETuple (EVar "mid") (EBinOp "++" (EVar "decls") (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "driver")) (EVar "asyncMainPinName")) (EVar "decls")))) (ETuple (EVar "mid") (EVar "decls"))))
(DTypeSig false "wrapAsyncEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "wrapAsyncEntry" ((PList)) (EListLit))
(DFunDef false "wrapAsyncEntry" ((PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EBinOp "::" (EVar "asyncPinImport") (EApp (EApp (EVar "map") (EVar "wrapAsyncMainDecl")) (EApp (EApp (EVar "filter") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isMainTypeSig") (EVar "d"))))) (EVar "decls")))))))
(DFunDef false "wrapAsyncEntry" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "wrapAsyncEntry") (EVar "rest"))))
(DTypeSig false "synthLoc" (TyCon "Loc"))
(DFunDef false "synthLoc" () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "asyncPinImport" (TyCon "Decl"))
(DFunDef false "asyncPinImport" () (EApp (EApp (EApp (EVar "DUse") (EVar "False")) (EApp (EApp (EVar "UseGroup") (EListLit (EVar "asyncModuleId"))) (EListLit (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "asyncMainPinName")) (EVar "False")) (EVar "synthLoc")) (EVar "None"))))) (EVar "synthLoc")))
(DTypeSig false "wrapAsyncMainDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "wrapAsyncMainDecl" ((PCon "DFunDef" (PVar "vis") (PLit (LString "main")) (PList) (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (ELit (LString "main"))) (EListLit)) (EApp (EApp (EVar "wrapCall") (EVar "asyncMainPinName")) (EVar "body"))))
(DFunDef false "wrapAsyncMainDecl" ((PCon "DAttrib" (PVar "a") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "a")) (EApp (EVar "wrapAsyncMainDecl") (EVar "d"))))
(DFunDef false "wrapAsyncMainDecl" ((PVar "d")) (EVar "d"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" false) (mem "Loc" true) (mem "UsePath" true) (mem "UseMember" true))))
(DUse false (UseGroup ("types" "typecheck") ((mem "mainTypeIsUnit" false) (mem "mainTypeIsAsync" false) (mem "checkOneDiagsSynthetic" false) (mem "setCoherenceUserDecls" false) (mem "TcDiag" false))))
(DTypeSig false "entryPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "entryPair" ((PList)) (EVar "None"))
(DFunDef false "entryPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "entryPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "entryPair") (EVar "rest")))
(DTypeSig false "findMainParams" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "findMainParams" ((PList)) (EVar "None"))
(DFunDef false "findMainParams" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "findMainParams") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findMainParams" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PVar "ps") PWild) PWild)) (EApp (EVar "Some") (EVar "ps")))
(DFunDef false "findMainParams" ((PCons PWild (PVar "rest"))) (EApp (EVar "findMainParams") (EVar "rest")))
(DTypeSig false "definesPrintln" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "definesPrintln" ((PList)) (EVar "False"))
(DFunDef false "definesPrintln" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "definesPrintln") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definesPrintln" ((PCons (PCon "DFunDef" PWild (PLit (LString "println")) PWild PWild) PWild)) (EVar "True"))
(DFunDef false "definesPrintln" ((PCons PWild (PVar "rest"))) (EApp (EVar "definesPrintln") (EVar "rest")))
(DTypeSig true "shouldAutoPrintMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool"))))
(DFunDef false "shouldAutoPrintMain" ((PVar "coreDecls") (PVar "modules")) (EIf (EBinOp "||" (EApp (EVar "mainTypeIsUnit") (ELit LUnit)) (EApp (EVar "mainTypeIsAsync") (ELit LUnit))) (EVar "False") (EIf (EApp (EVar "not") (EApp (EVar "definesPrintln") (EBinOp "++" (EVar "coreDecls") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))))) (EVar "False") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EVar "True")) (arm PWild () (EVar "False"))))))))
(DTypeSig false "isMainTypeSig" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isMainTypeSig" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isMainTypeSig") (EVar "d")))
(DFunDef false "isMainTypeSig" ((PCon "DTypeSig" PWild (PLit (LString "main")) PWild)) (EVar "True"))
(DFunDef false "isMainTypeSig" (PWild) (EVar "False"))
(DTypeSig true "autoPrintWrapModules" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "autoPrintWrapModules" ((PList)) (EListLit))
(DFunDef false "autoPrintWrapModules" ((PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EApp (EApp (EMethodRef "map") (EVar "wrapMainDecl")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isMainTypeSig") (EVar "d"))))) (EVar "decls"))))))
(DFunDef false "autoPrintWrapModules" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "autoPrintWrapModules") (EVar "rest"))))
(DTypeSig false "wrapMainDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "wrapMainDecl" ((PCon "DFunDef" (PVar "vis") (PLit (LString "main")) (PList) (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (ELit (LString "main"))) (EListLit)) (EApp (EVar "wrapPrintln") (EVar "body"))))
(DFunDef false "wrapMainDecl" ((PCon "DAttrib" (PVar "a") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "a")) (EApp (EVar "wrapMainDecl") (EVar "d"))))
(DFunDef false "wrapMainDecl" ((PVar "d")) (EVar "d"))
(DTypeSig true "autoPrintPinName" (TyCon "String"))
(DFunDef false "autoPrintPinName" () (ELit (LString "0autoprintln")))
(DTypeSig true "autoPrintPinCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "autoPrintPinCore" ((PVar "coreDecls")) (EBinOp "++" (EVar "coreDecls") (EApp (EVar "pinnedPrintlnDecls") (EVar "coreDecls"))))
(DTypeSig false "pinnedPrintlnDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "pinnedPrintlnDecls" ((PVar "decls")) (EApp (EApp (EApp (EVar "pinnedCopies") (ELit (LString "println"))) (EVar "autoPrintPinName")) (EVar "decls")))
(DTypeSig false "pinnedCopies" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "pinnedCopies" (PWild PWild (PList)) (EListLit))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DTypeSig" PWild (PVar "n") (PVar "ty")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EVar "DTypeSig") (EVar "True")) (EVar "pin")) (EVar "ty")) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "True")) (EVar "pin")) (EVar "ps")) (EVar "body")) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest")))
(DTypeSig false "wrapPrintln" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "wrapPrintln" ((PVar "body")) (EApp (EApp (EVar "wrapCall") (EVar "autoPrintPinName")) (EVar "body")))
(DTypeSig false "wrapCall" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "wrapCall" ((PVar "callee") (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "callee"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "inner")))))
(DFunDef false "wrapCall" ((PVar "callee") (PVar "body")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "callee"))) (EVar "body")))
(DTypeSig true "underivedMainDiags" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "TcDiag"))))))
(DFunDef false "underivedMainDiags" ((PVar "runtimeDecls") (PVar "coreDecls") (PList (PTuple (PVar "mid") (PVar "entryDecls")))) (EBlock (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "entryDecls"))) (DoLet false false (PTuple (PVar "tcErrs") PWild) (EApp (EApp (EApp (EVar "checkOneDiagsSynthetic") (EVar "runtimeDecls")) (EVar "coreDecls")) (ETuple (EVar "mid") (EVar "entryDecls")))) (DoExpr (EVar "tcErrs"))))
(DFunDef false "underivedMainDiags" (PWild PWild PWild) (EListLit))
(DTypeSig true "asyncMainPinName" (TyCon "String"))
(DFunDef false "asyncMainPinName" () (ELit (LString "0runasync")))
(DTypeSig false "asyncModuleId" (TyCon "String"))
(DFunDef false "asyncModuleId" () (ELit (LString "async")))
(DTypeSig true "shouldAsyncWrapMain" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool"))))
(DFunDef false "shouldAsyncWrapMain" ((PVar "driver") (PVar "modules")) (EIf (EApp (EVar "not") (EApp (EVar "mainTypeIsAsync") (ELit LUnit))) (EVar "False") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EApp (EApp (EDictApp "any") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EVar "asyncModuleId")) (EApp (EApp (EVar "definesFun") (EVar "driver")) (EApp (EVar "snd") (EVar "p")))))) (EVar "modules"))) (arm PWild () (EVar "False")))))))
(DTypeSig false "definesFun" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "definesFun" (PWild (PList)) (EVar "False"))
(DFunDef false "definesFun" ((PVar "n") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "definesFun") (EVar "n")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definesFun" ((PVar "n") (PCons (PCon "DFunDef" PWild (PVar "m") PWild PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EVar "True") (EApp (EApp (EVar "definesFun") (EVar "n")) (EVar "rest"))))
(DFunDef false "definesFun" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "definesFun") (EVar "n")) (EVar "rest")))
(DTypeSig true "asyncWrapModules" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "asyncWrapModules" ((PVar "driver") (PVar "modules")) (EApp (EVar "wrapAsyncEntry") (EApp (EApp (EMethodRef "map") (EApp (EVar "pinAsyncDriver") (EVar "driver"))) (EVar "modules"))))
(DTypeSig false "pinAsyncDriver" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "pinAsyncDriver" ((PVar "driver") (PTuple (PVar "mid") (PVar "decls"))) (EIf (EBinOp "==" (EVar "mid") (EVar "asyncModuleId")) (ETuple (EVar "mid") (EBinOp "++" (EVar "decls") (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "driver")) (EVar "asyncMainPinName")) (EVar "decls")))) (ETuple (EVar "mid") (EVar "decls"))))
(DTypeSig false "wrapAsyncEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "wrapAsyncEntry" ((PList)) (EListLit))
(DFunDef false "wrapAsyncEntry" ((PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EBinOp "::" (EVar "asyncPinImport") (EApp (EApp (EMethodRef "map") (EVar "wrapAsyncMainDecl")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isMainTypeSig") (EVar "d"))))) (EVar "decls")))))))
(DFunDef false "wrapAsyncEntry" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "wrapAsyncEntry") (EVar "rest"))))
(DTypeSig false "synthLoc" (TyCon "Loc"))
(DFunDef false "synthLoc" () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "asyncPinImport" (TyCon "Decl"))
(DFunDef false "asyncPinImport" () (EApp (EApp (EApp (EVar "DUse") (EVar "False")) (EApp (EApp (EVar "UseGroup") (EListLit (EVar "asyncModuleId"))) (EListLit (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "asyncMainPinName")) (EVar "False")) (EVar "synthLoc")) (EVar "None"))))) (EVar "synthLoc")))
(DTypeSig false "wrapAsyncMainDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "wrapAsyncMainDecl" ((PCon "DFunDef" (PVar "vis") (PLit (LString "main")) (PList) (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (ELit (LString "main"))) (EListLit)) (EApp (EApp (EVar "wrapCall") (EVar "asyncMainPinName")) (EVar "body"))))
(DFunDef false "wrapAsyncMainDecl" ((PCon "DAttrib" (PVar "a") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "a")) (EApp (EVar "wrapAsyncMainDecl") (EVar "d"))))
(DFunDef false "wrapAsyncMainDecl" ((PVar "d")) (EVar "d"))
