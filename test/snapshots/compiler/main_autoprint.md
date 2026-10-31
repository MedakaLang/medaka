# META
source_lines=439
stages=DESUGAR,MARK
# SOURCE
import string.{split}
-- compiler/driver/main_autoprint.mdk — shared composite-`main` auto-print wrap.
--
-- A bare non-Unit VALUE `main` (`main = ("abc", 1.23)`, `main = [1,2,3]`, a
-- `deriving Display` ADT, …) would otherwise CRASH the emitter (`emitPrint` panics on a
-- non-scalar `main`).  This module implements the uniform fix from
-- archive/design/COMPOSITE-MAIN-AUTOPRINT-DESIGN.md §10: rewrite the entry decl
--   main = <e>   ⟶   main = 0autoprintln <e>
-- where `0autoprintln` is the PRELUDE's own `println` declaration re-bound under
-- a name no user program can spell (`autoPrintPinCore`; `display` renders → raw
-- strings, `(a, b)` tuples, `[1, 2, 3]` lists, derived ctors).  See
-- `autoPrintPinCore`'s own comment for why no SPELLING of this call — `println`,
-- or `putStrLn (display …)` — can be safe (#2185, and its F1/F2 recurrence)
-- so the value flows through the ordinary polymorphic print path every
-- backend already compiles.  A wrapped `main` (`mainIsWrapped`) suppresses the
-- emitter's own scalar auto-print, so a value is printed exactly ONCE.
--
-- SCOPE / re-mint safety: the wrap fires ONLY on a bare zero-arg non-Unit/non-Async
-- value main.  Every compiler-graph `main` is Unit/`<IO>`-typed, so
-- `shouldAutoPrintMain` is always False on the compiler's own source → the emitter
-- output on the compiler graph is byte-identical → the self-compile fixpoint is
-- stable and NO seed re-mint is owed (design §6).
--
-- UNDERIVED detection: a bare ADT main with no `Display` instance (`data H = H;
-- main = H`) must surface the clean `No impl of Display for H; add 'deriving
-- Display'` error, NOT a miscompile.  The wrap's one class obligation is
-- `Display τ_main`, and the drive that checks the entry module poses it itself
-- (`autoPrintWanted`, types/typecheck.mdk) when its caller passes the syntactic
-- candidate below (`valueMainCandidate`).  The wrap is applied to that drive's
-- elaborated trees (`executedTrees`), so the program is elaborated once.

import frontend.ast.{
  Decl(..),
  Expr(..),
  Pat,
  Loc(..),
  UsePath(..),
  UseMember(..),
}
import types.private_mangle.{mangledName}
import types.publish.{TcReport(..), CheckedProgram(..), EntryOutcome(..)}
import types.program_facts.{ProgramFacts(..)}
import types.tc_types.{DriveInputs(..)}
import types.capability_manifest.{
  EntryKey(..), ManifestSelector(..), ManifestRequirement(..),
  InvocationProtocol(..)
}

export
mainEntryKey : List (String, List Decl) -> EntryKey
mainEntryKey modules = EntryKey {
  moduleId = match entryPair modules
    Some (mid, _) => mid
    None => "",
  binding = "main",
}

export
executedMainInputs : DriveInputs ->
  EntryKey ->
  List (String, List Decl) ->
  DriveInputs
executedMainInputs inputs driver modules = { inputs |
  diExecutedMainDriver = Some driver,
  diManifestRequests = match entryPair modules
    Some (_, decls) =>
      if isSome (findMainParams decls) then
        ExactEntry (mainEntryKey modules) ExecutedMain
          :: inputs.diManifestRequests
      else
        inputs.diManifestRequests
    None => inputs.diManifestRequests,
}

export
executedMainRequirement : List (String, List Decl) -> ManifestRequirement
executedMainRequirement modules =
  CheckedEntry (mainEntryKey modules) ExecutedMain

-- The loader hands modules dependency-first, so the ENTRY module is last.
entryPair : List (String, List Decl) -> Option (String, List Decl)
entryPair [] = None
entryPair [p] = Some p
entryPair (_ :: rest) = entryPair rest

-- Find the top-level `main`'s param list among a module's decls (skipping @attr
-- wrappers), so the caller can require an EMPTY param list (a value main — a
-- function-shaped `main () =`/`main x =` is diagnosed instead, see
-- `mainEntryError` in driver/diagnostics.mdk, and is NEVER auto-printed).
findMainParams : List Decl -> Option (List Pat)
findMainParams [] = None
findMainParams ((DAttrib _ d) :: rest) = findMainParams (d :: rest)
findMainParams ((DFunDef _ "main" ps _ _ _) :: _) = Some ps
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
definesPrintln ((DFunDef _ "println" _ _ _ _) :: _) = True
definesPrintln (_ :: rest) = definesPrintln rest

-- Auto-print fires iff main's inferred type is neither Unit-shaped (`Unit`, or
-- a bare type variable: see `eoMainIsUnit`) nor `Async _`, and the program is a
-- value-main candidate. [outcome] is from the elaboration that judged the program.
export
shouldAutoPrintMain : EntryOutcome ->
  List Decl ->
  List (String, List Decl) ->
  Bool
shouldAutoPrintMain outcome coreDecls modules =
  if outcome.eoMainIsUnit || outcome.eoMainIsAsync then
    False
  else
    valueMainCandidate coreDecls modules

-- The syntactic half of `shouldAutoPrintMain`, readable before any drive: the
-- entry `main` is a zero-arg VALUE (empty param list) and `println` is in scope.
-- A drive that checks the entry module takes it as its value-main candidate and
-- poses the auto-print obligation from `main`'s own scheme.
export
valueMainCandidate : List Decl -> List (String, List Decl) -> Bool
valueMainCandidate coreDecls modules =
  if not (definesPrintln (coreDecls ++ flatMap snd modules)) then
    False
  else match entryPair modules
    None => False
    Some (_, decls) => match findMainParams decls
      Some [] => True
      _ => False

-- True iff the decl is `main`'s explicit type signature (`main : T`), possibly
-- @attr-wrapped.  A wrapped `main` is the driver's result (`<Stdout> Unit` for the
-- auto-print wrap), so `T` no longer describes it and the wrap removes the
-- signature from the decl list.
isMainTypeSig : Decl -> Bool
isMainTypeSig (DAttrib _ d) = isMainTypeSig d
isMainTypeSig (DTypeSig _ "main" _ _) = True
isMainTypeSig _ = False

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
-- (`ownMethodIdent`, `methodOwnScope` in `compiler/types/typecheck.mdk`:
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
-- So the wrap denotes THAT declaration: [coreDecls] is the ELABORATED
-- prelude, and this copies its `println : Display a => a -> <IO> Unit`
-- signature and clauses, dict parameter included, under an unspellable name
-- and appends them to the core decl list.  `executedTrees` applies the copy to
-- `main`'s body as `EDictAt autoPrintPinName ev`, the dictionary the drive's
-- evidence names.  The copied body was elaborated in the PRELUDE's scope, so its
-- `display`/`putStrLn` resolve exactly as `println`'s own do, and the reference
-- cannot be captured because the name cannot be declared.  No name the wrap
-- synthesizes is resolved in user scope — including `putStrLn`, whose
-- (narrower) capture vector goes with it.
--
-- Copies, not a hand-built AST: no second spelling of
-- `Display a => a -> <IO> Unit` is minted that could drift from the prelude's.
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
pinnedCopies origin pin ((DTypeSig _ n ty site) :: rest) =
  if n == origin then
    DTypeSig True pin ty site :: pinnedCopies origin pin rest
  else
    pinnedCopies origin pin rest
pinnedCopies origin pin ((DFunDef _ n ps body site bid) :: rest) =
  if n == origin then
    DFunDef True pin ps body site bid :: pinnedCopies origin pin rest
  else
    pinnedCopies origin pin rest
pinnedCopies origin pin (_ :: rest) = pinnedCopies origin pin rest

-- The trees an executing driver runs, built from the drive that judged the
-- program.  [source] is the program the drive read and [elaborated] its trees.
--   * A printed value `main`: `main = <e>` becomes `main = 0autoprintln <e>`.
--     The callee is the drive's own elaborated copy of `println`, re-bound under
--     the pin (`autoPrintPinCore`).  The application is dict-passed by the
--     auto-print evidence the checked program's entry outcome published.
--   * An `Async` main: `main = <e>` becomes `main = 0runasync <e>`.  Its driver
--     is unconstrained, so it needs no evidence.
--   * Any other `main`: the trees unchanged.
-- A printed `main` with no evidence is refused: running it unprinted would exit
-- 0 with nothing on stdout.
export
executedTrees : EntryOutcome ->
  EntryKey ->
  (List Decl, List (String, List Decl)) ->
  (List Decl, List (String, List Decl)) ->
  Result String (List Decl, List (String, List Decl))
executedTrees outcome driver (coreD, modsD) (coreE, modsE) =
  if shouldAutoPrintMain outcome coreD modsD then match outcome.eoAutoPrint
    Some ev => Ok (
      autoPrintPinCore coreE,
      onEntry (wrapEntryMain (EDictAt autoPrintPinName ev)) modsE,
    )
    None =>
      Err
        "internal error: the typecheck published no evidence for printing the value `main`"
  else if shouldAsyncWrapMain outcome driver modsD then
    Ok (coreE, asyncWrapModules driver modsE)
  else
    Ok (coreE, modsE)

-- `executedTrees` over the trees and auto-print evidence of the drive [report]
-- judged.  A report with no checked program has nothing to run: the driver's
-- gate refused it before this point, so reaching here is an internal error.
export
executedFromReport : TcReport ->
  EntryKey ->
  (List Decl, List (String, List Decl)) ->
  Result String (List Decl, List (String, List Decl))
executedFromReport report driver source = match report.trChecked
  Some checked => match checked.cpTrees
    Some trees => executedTrees checked.cpEntryOutcome driver source trees
    None => noChecked
  None => noChecked

noChecked : Result String (List Decl, List (String, List Decl))
noChecked =
  Err "internal error: the typecheck published no checked program to run"

-- True iff the entry `main` is a driver wrap (`executedTrees`), before or after
-- `mangleUnitsEv` renames the pins.  The wrapped `main`'s result is `Unit`, so
-- an emitter's scalar auto-print must not print it again.
export
mainIsWrapped : List (String, List Decl) -> Bool
mainIsWrapped modules = match entryPair modules
  Some (_, decls) => wrappedMainIn decls
  None => False

-- A backend lowers the trees after the driver rewrites their entry.  Keep its
-- entry fact in step with those trees: either driver wrapper has a Unit result,
-- and has already consumed any auto-print evidence.
export
factsForExecutedTrees : ProgramFacts -> List (String, List Decl) -> ProgramFacts
factsForExecutedTrees facts modules =
  if mainIsWrapped modules then
    { facts | pfEntryOutcome = map executedEntryOutcome facts.pfEntryOutcome }
  else
    facts

executedEntryOutcome : EntryOutcome -> EntryOutcome
executedEntryOutcome outcome = { outcome |
  eoMainIsUnit = True,
  eoMainIsFloat = False,
  eoMainIsAsync = False,
  eoMainAsyncPayloadIsUnit = False,
  eoAutoPrint = None,
}

wrappedMainIn : List Decl -> Bool
wrappedMainIn [] = False
wrappedMainIn ((DAttrib _ d) :: rest) = wrappedMainIn (d :: rest)
wrappedMainIn ((DFunDef _ "main" [] body _ _) :: _) = isWrapCall body
wrappedMainIn (_ :: rest) = wrappedMainIn rest

isWrapCall : Expr -> Bool
isWrapCall (ELoc _ e) = isWrapCall e
isWrapCall (EApp (EDictAt n _) _) =
  n == autoPrintPinName || n == mangledName "core" autoPrintPinName
isWrapCall (EApp (EVar n) _) =
  n == asyncMainPinName || n == mangledName asyncModuleId asyncMainPinName
isWrapCall _ = False

-- [f] applied to the entry module's decls.
onEntry : (List Decl -> List Decl) ->
  List (String, List Decl) ->
  List (String, List Decl)
onEntry _ [] = []
onEntry f [(mid, decls)] = [(mid, f decls)]
onEntry f (p :: rest) = p :: onEntry f rest

-- `main = <e>` becomes `main = callee <e>`, and `main`'s signature is dropped.
wrapEntryMain : Expr -> List Decl -> List Decl
wrapEntryMain callee decls =
  map (wrapMainDecl callee) (filter (d => not (isMainTypeSig d)) decls)

wrapMainDecl : Expr -> Decl -> Decl
wrapMainDecl callee (DFunDef vis "main" [] body site bid) =
  DFunDef vis "main" [] (wrapCall callee site body) site bid
wrapMainDecl callee (DAttrib a d) = DAttrib a (wrapMainDecl callee d)
wrapMainDecl _ d = d

-- `<e>` → `callee <e>`, keeping the body's outer `ELoc` around the application.
-- A body with none (an application such as `Err "x"`) is located at the `main`
-- binding [site].
wrapCall : Expr -> Loc -> Expr -> Expr
wrapCall callee _ (ELoc l inner) = ELoc l (EApp callee (ELoc l inner))
wrapCall callee site body = ELoc site (EApp callee body)

-- ── `main : Async _` driver wrap (ASYNC-DESIGN D5, ASYNC-RUNTIME-DESIGN §4.4) ──
-- A `main` whose type heads in `Async` is an inert VALUE until a driver forces
-- it, so forcing it alone runs nothing (#2506).  Every engine drives it through
-- the same rewrite the auto-print wrap uses:
--   main = <e>   ⟶   main = 0runasync <e>
-- where `0runasync` is the `async` module's own entry driver (`runAsyncMain` on
-- every target; it declares a `Unit` result so no backend auto-prints it)
-- re-bound under an unspellable name and
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
export
shouldAsyncWrapMain : EntryOutcome ->
  EntryKey ->
  List (String, List Decl) ->
  Bool
shouldAsyncWrapMain outcome driver modules =
  if not (outcome.eoMainIsAsync && outcome.eoMainAsyncPayloadIsUnit) then
    False
  else match entryPair modules
    None => False
    Some (_, decls) => match findMainParams decls
      Some [] =>
        any
          (p => fst p == driver.moduleId && definesFun driver.binding (snd p))
          modules
      _ => False

-- The one `Async` main shape the drivers cannot take: a payload other than
-- `Unit` (`main : Async e Int`).  Every driver reports this before the rewrite
-- so the failure is this message, not the driver's own unification error.
export
asyncMainShapeError : EntryOutcome -> List (String, List Decl) -> Option String
asyncMainShapeError outcome modules =
  if not outcome.eoMainIsAsync || outcome.eoMainAsyncPayloadIsUnit then
    None
  else match entryPair modules
    None => None
    Some (_, decls) => match findMainParams decls
      Some [] =>
        Some
          "main : Async e a must have a Unit payload (`main : Async e Unit`) — the driver runs the program for its effects and has nowhere to put a value; print it inside the program instead"
      _ => None

definesFun : String -> List Decl -> Bool
definesFun _ [] = False
definesFun n ((DAttrib _ d) :: rest) = definesFun n (d :: rest)
definesFun n ((DFunDef _ m _ _ _ _) :: rest) =
  if m == n then True else definesFun n rest
definesFun n (_ :: rest) = definesFun n rest

-- Pin `driver` in the `async` module under `asyncMainPinName`, import the pin
-- into the entry module, and rewrite `main = <e>` to `main = 0runasync <e>`.
-- The entry's `main : T` signature is dropped: the wrapped main's type is the
-- driver's result, not `Async`.
export
asyncWrapModules : EntryKey ->
  List (String, List Decl) ->
  List (String, List Decl)
asyncWrapModules driver modules =
  wrapAsyncEntry driver (map (pinAsyncDriver driver) modules)

pinAsyncDriver : EntryKey -> (String, List Decl) -> (String, List Decl)
pinAsyncDriver driver (mid, decls) =
  if mid == driver.moduleId then
    (mid, decls ++ pinnedCopies driver.binding asyncMainPinName decls)
  else
    (mid, decls)

wrapAsyncEntry : EntryKey ->
  List (String, List Decl) ->
  List (String, List Decl)
wrapAsyncEntry driver = onEntry (decls =>
  asyncPinImport driver :: wrapEntryMain (EVar asyncMainPinName) decls)

synthLoc : Loc
synthLoc = Loc "" 0 0 0 0

asyncPinImport : EntryKey -> Decl
asyncPinImport driver =
  DUse
    False
    (UseGroup (split "." driver.moduleId) [
      UseMember asyncMainPinName False synthLoc None,
    ])
    synthLoc
# DESUGAR
(DUse false (UseGroup ("string") ((mem "split" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" false) (mem "Loc" true) (mem "UsePath" true) (mem "UseMember" true))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "mangledName" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcReport" true) (mem "CheckedProgram" true) (mem "EntryOutcome" true))))
(DUse false (UseGroup ("types" "program_facts") ((mem "ProgramFacts" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveInputs" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestSelector" true) (mem "ManifestRequirement" true) (mem "InvocationProtocol" true))))
(DTypeSig true "mainEntryKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EntryKey")))
(DFunDef false "mainEntryKey" ((PVar "modules")) (ERecordCreate "EntryKey" ((fa "moduleId" (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "Some" (PTuple (PVar "mid") PWild)) () (EVar "mid")) (arm (PCon "None") () (ELit (LString ""))))) (fa "binding" (ELit (LString "main"))))))
(DTypeSig true "executedMainInputs" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "EntryKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "DriveInputs")))))
(DFunDef false "executedMainInputs" ((PVar "inputs") (PVar "driver") (PVar "modules")) (ERecordUpdate (EVar "inputs") ((fa "diExecutedMainDriver" (EApp (EVar "Some") (EVar "driver"))) (fa "diManifestRequests" (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EIf (EApp (EVar "isSome") (EApp (EVar "findMainParams") (EVar "decls"))) (EBinOp "::" (EApp (EApp (EVar "ExactEntry") (EApp (EVar "mainEntryKey") (EVar "modules"))) (EVar "ExecutedMain")) (EFieldAccess (EVar "inputs") "diManifestRequests")) (EFieldAccess (EVar "inputs") "diManifestRequests"))) (arm (PCon "None") () (EFieldAccess (EVar "inputs") "diManifestRequests")))))))
(DTypeSig true "executedMainRequirement" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ManifestRequirement")))
(DFunDef false "executedMainRequirement" ((PVar "modules")) (EApp (EApp (EVar "CheckedEntry") (EApp (EVar "mainEntryKey") (EVar "modules"))) (EVar "ExecutedMain")))
(DTypeSig false "entryPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "entryPair" ((PList)) (EVar "None"))
(DFunDef false "entryPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "entryPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "entryPair") (EVar "rest")))
(DTypeSig false "findMainParams" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "findMainParams" ((PList)) (EVar "None"))
(DFunDef false "findMainParams" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "findMainParams") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findMainParams" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PVar "ps") PWild PWild PWild) PWild)) (EApp (EVar "Some") (EVar "ps")))
(DFunDef false "findMainParams" ((PCons PWild (PVar "rest"))) (EApp (EVar "findMainParams") (EVar "rest")))
(DTypeSig false "definesPrintln" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "definesPrintln" ((PList)) (EVar "False"))
(DFunDef false "definesPrintln" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "definesPrintln") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definesPrintln" ((PCons (PCon "DFunDef" PWild (PLit (LString "println")) PWild PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "definesPrintln" ((PCons PWild (PVar "rest"))) (EApp (EVar "definesPrintln") (EVar "rest")))
(DTypeSig true "shouldAutoPrintMain" (TyFun (TyCon "EntryOutcome") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool")))))
(DFunDef false "shouldAutoPrintMain" ((PVar "outcome") (PVar "coreDecls") (PVar "modules")) (EIf (EBinOp "||" (EFieldAccess (EVar "outcome") "eoMainIsUnit") (EFieldAccess (EVar "outcome") "eoMainIsAsync")) (EVar "False") (EApp (EApp (EVar "valueMainCandidate") (EVar "coreDecls")) (EVar "modules"))))
(DTypeSig true "valueMainCandidate" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool"))))
(DFunDef false "valueMainCandidate" ((PVar "coreDecls") (PVar "modules")) (EIf (EApp (EVar "not") (EApp (EVar "definesPrintln") (EBinOp "++" (EVar "coreDecls") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))))) (EVar "False") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EVar "True")) (arm PWild () (EVar "False")))))))
(DTypeSig false "isMainTypeSig" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isMainTypeSig" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isMainTypeSig") (EVar "d")))
(DFunDef false "isMainTypeSig" ((PCon "DTypeSig" PWild (PLit (LString "main")) PWild PWild)) (EVar "True"))
(DFunDef false "isMainTypeSig" (PWild) (EVar "False"))
(DTypeSig true "autoPrintPinName" (TyCon "String"))
(DFunDef false "autoPrintPinName" () (ELit (LString "0autoprintln")))
(DTypeSig true "autoPrintPinCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "autoPrintPinCore" ((PVar "coreDecls")) (EBinOp "++" (EVar "coreDecls") (EApp (EVar "pinnedPrintlnDecls") (EVar "coreDecls"))))
(DTypeSig false "pinnedPrintlnDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "pinnedPrintlnDecls" ((PVar "decls")) (EApp (EApp (EApp (EVar "pinnedCopies") (ELit (LString "println"))) (EVar "autoPrintPinName")) (EVar "decls")))
(DTypeSig false "pinnedCopies" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "pinnedCopies" (PWild PWild (PList)) (EListLit))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DTypeSig" PWild (PVar "n") (PVar "ty") (PVar "site")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DTypeSig") (EVar "True")) (EVar "pin")) (EVar "ty")) (EVar "site")) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PVar "site") (PVar "bid")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "True")) (EVar "pin")) (EVar "ps")) (EVar "body")) (EVar "site")) (EVar "bid")) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest")))
(DTypeSig true "executedTrees" (TyFun (TyCon "EntryOutcome") (TyFun (TyCon "EntryKey") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "executedTrees" ((PVar "outcome") (PVar "driver") (PTuple (PVar "coreD") (PVar "modsD")) (PTuple (PVar "coreE") (PVar "modsE"))) (EIf (EApp (EApp (EApp (EVar "shouldAutoPrintMain") (EVar "outcome")) (EVar "coreD")) (EVar "modsD")) (EMatch (EFieldAccess (EVar "outcome") "eoAutoPrint") (arm (PCon "Some" (PVar "ev")) () (EApp (EVar "Ok") (ETuple (EApp (EVar "autoPrintPinCore") (EVar "coreE")) (EApp (EApp (EVar "onEntry") (EApp (EVar "wrapEntryMain") (EApp (EApp (EVar "EDictAt") (EVar "autoPrintPinName")) (EVar "ev")))) (EVar "modsE"))))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "internal error: the typecheck published no evidence for printing the value `main`"))))) (EIf (EApp (EApp (EApp (EVar "shouldAsyncWrapMain") (EVar "outcome")) (EVar "driver")) (EVar "modsD")) (EApp (EVar "Ok") (ETuple (EVar "coreE") (EApp (EApp (EVar "asyncWrapModules") (EVar "driver")) (EVar "modsE")))) (EApp (EVar "Ok") (ETuple (EVar "coreE") (EVar "modsE"))))))
(DTypeSig true "executedFromReport" (TyFun (TyCon "TcReport") (TyFun (TyCon "EntryKey") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "executedFromReport" ((PVar "report") (PVar "driver") (PVar "source")) (EMatch (EFieldAccess (EVar "report") "trChecked") (arm (PCon "Some" (PVar "checked")) () (EMatch (EFieldAccess (EVar "checked") "cpTrees") (arm (PCon "Some" (PVar "trees")) () (EApp (EApp (EApp (EApp (EVar "executedTrees") (EFieldAccess (EVar "checked") "cpEntryOutcome")) (EVar "driver")) (EVar "source")) (EVar "trees"))) (arm (PCon "None") () (EVar "noChecked")))) (arm (PCon "None") () (EVar "noChecked"))))
(DTypeSig false "noChecked" (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "noChecked" () (EApp (EVar "Err") (ELit (LString "internal error: the typecheck published no checked program to run"))))
(DTypeSig true "mainIsWrapped" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool")))
(DFunDef false "mainIsWrapped" ((PVar "modules")) (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EApp (EVar "wrappedMainIn") (EVar "decls"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "factsForExecutedTrees" (TyFun (TyCon "ProgramFacts") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ProgramFacts"))))
(DFunDef false "factsForExecutedTrees" ((PVar "facts") (PVar "modules")) (EIf (EApp (EVar "mainIsWrapped") (EVar "modules")) (ERecordUpdate (EVar "facts") ((fa "pfEntryOutcome" (EApp (EApp (EVar "map") (EVar "executedEntryOutcome")) (EFieldAccess (EVar "facts") "pfEntryOutcome"))))) (EVar "facts")))
(DTypeSig false "executedEntryOutcome" (TyFun (TyCon "EntryOutcome") (TyCon "EntryOutcome")))
(DFunDef false "executedEntryOutcome" ((PVar "outcome")) (ERecordUpdate (EVar "outcome") ((fa "eoMainIsUnit" (EVar "True")) (fa "eoMainIsFloat" (EVar "False")) (fa "eoMainIsAsync" (EVar "False")) (fa "eoMainAsyncPayloadIsUnit" (EVar "False")) (fa "eoAutoPrint" (EVar "None")))))
(DTypeSig false "wrappedMainIn" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "wrappedMainIn" ((PList)) (EVar "False"))
(DFunDef false "wrappedMainIn" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "wrappedMainIn") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "wrappedMainIn" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PList) (PVar "body") PWild PWild) PWild)) (EApp (EVar "isWrapCall") (EVar "body")))
(DFunDef false "wrappedMainIn" ((PCons PWild (PVar "rest"))) (EApp (EVar "wrappedMainIn") (EVar "rest")))
(DTypeSig false "isWrapCall" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isWrapCall" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isWrapCall") (EVar "e")))
(DFunDef false "isWrapCall" ((PCon "EApp" (PCon "EDictAt" (PVar "n") PWild) PWild)) (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "autoPrintPinName")) (EBinOp "==" (EVar "n") (EApp (EApp (EVar "mangledName") (ELit (LString "core"))) (EVar "autoPrintPinName")))))
(DFunDef false "isWrapCall" ((PCon "EApp" (PCon "EVar" (PVar "n")) PWild)) (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "asyncMainPinName")) (EBinOp "==" (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "asyncModuleId")) (EVar "asyncMainPinName")))))
(DFunDef false "isWrapCall" (PWild) (EVar "False"))
(DTypeSig false "onEntry" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "onEntry" (PWild (PList)) (EListLit))
(DFunDef false "onEntry" ((PVar "f") (PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "f") (EVar "decls")))))
(DFunDef false "onEntry" ((PVar "f") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EApp (EVar "onEntry") (EVar "f")) (EVar "rest"))))
(DTypeSig false "wrapEntryMain" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "wrapEntryMain" ((PVar "callee") (PVar "decls")) (EApp (EApp (EVar "map") (EApp (EVar "wrapMainDecl") (EVar "callee"))) (EApp (EApp (EVar "filter") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isMainTypeSig") (EVar "d"))))) (EVar "decls"))))
(DTypeSig false "wrapMainDecl" (TyFun (TyCon "Expr") (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "wrapMainDecl" ((PVar "callee") (PCon "DFunDef" (PVar "vis") (PLit (LString "main")) (PList) (PVar "body") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (ELit (LString "main"))) (EListLit)) (EApp (EApp (EApp (EVar "wrapCall") (EVar "callee")) (EVar "site")) (EVar "body"))) (EVar "site")) (EVar "bid")))
(DFunDef false "wrapMainDecl" ((PVar "callee") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "a")) (EApp (EApp (EVar "wrapMainDecl") (EVar "callee")) (EVar "d"))))
(DFunDef false "wrapMainDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "wrapCall" (TyFun (TyCon "Expr") (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "wrapCall" ((PVar "callee") PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "EApp") (EVar "callee")) (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "inner")))))
(DFunDef false "wrapCall" ((PVar "callee") (PVar "site") (PVar "body")) (EApp (EApp (EVar "ELoc") (EVar "site")) (EApp (EApp (EVar "EApp") (EVar "callee")) (EVar "body"))))
(DTypeSig true "asyncMainPinName" (TyCon "String"))
(DFunDef false "asyncMainPinName" () (ELit (LString "0runasync")))
(DTypeSig false "asyncModuleId" (TyCon "String"))
(DFunDef false "asyncModuleId" () (ELit (LString "async")))
(DTypeSig true "shouldAsyncWrapMain" (TyFun (TyCon "EntryOutcome") (TyFun (TyCon "EntryKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool")))))
(DFunDef false "shouldAsyncWrapMain" ((PVar "outcome") (PVar "driver") (PVar "modules")) (EIf (EApp (EVar "not") (EBinOp "&&" (EFieldAccess (EVar "outcome") "eoMainIsAsync") (EFieldAccess (EVar "outcome") "eoMainAsyncPayloadIsUnit"))) (EVar "False") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EApp (EApp (EVar "any") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EFieldAccess (EVar "driver") "moduleId")) (EApp (EApp (EVar "definesFun") (EFieldAccess (EVar "driver") "binding")) (EApp (EVar "snd") (EVar "p")))))) (EVar "modules"))) (arm PWild () (EVar "False")))))))
(DTypeSig true "asyncMainShapeError" (TyFun (TyCon "EntryOutcome") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "asyncMainShapeError" ((PVar "outcome") (PVar "modules")) (EIf (EBinOp "||" (EApp (EVar "not") (EFieldAccess (EVar "outcome") "eoMainIsAsync")) (EFieldAccess (EVar "outcome") "eoMainAsyncPayloadIsUnit")) (EVar "None") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EApp (EVar "Some") (ELit (LString "main : Async e a must have a Unit payload (`main : Async e Unit`) — the driver runs the program for its effects and has nowhere to put a value; print it inside the program instead")))) (arm PWild () (EVar "None")))))))
(DTypeSig false "definesFun" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "definesFun" (PWild (PList)) (EVar "False"))
(DFunDef false "definesFun" ((PVar "n") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "definesFun") (EVar "n")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definesFun" ((PVar "n") (PCons (PCon "DFunDef" PWild (PVar "m") PWild PWild PWild PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EVar "True") (EApp (EApp (EVar "definesFun") (EVar "n")) (EVar "rest"))))
(DFunDef false "definesFun" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "definesFun") (EVar "n")) (EVar "rest")))
(DTypeSig true "asyncWrapModules" (TyFun (TyCon "EntryKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "asyncWrapModules" ((PVar "driver") (PVar "modules")) (EApp (EApp (EVar "wrapAsyncEntry") (EVar "driver")) (EApp (EApp (EVar "map") (EApp (EVar "pinAsyncDriver") (EVar "driver"))) (EVar "modules"))))
(DTypeSig false "pinAsyncDriver" (TyFun (TyCon "EntryKey") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "pinAsyncDriver" ((PVar "driver") (PTuple (PVar "mid") (PVar "decls"))) (EIf (EBinOp "==" (EVar "mid") (EFieldAccess (EVar "driver") "moduleId")) (ETuple (EVar "mid") (EBinOp "++" (EVar "decls") (EApp (EApp (EApp (EVar "pinnedCopies") (EFieldAccess (EVar "driver") "binding")) (EVar "asyncMainPinName")) (EVar "decls")))) (ETuple (EVar "mid") (EVar "decls"))))
(DTypeSig false "wrapAsyncEntry" (TyFun (TyCon "EntryKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "wrapAsyncEntry" ((PVar "driver")) (EApp (EVar "onEntry") (ELam ((PVar "decls")) (EBinOp "::" (EApp (EVar "asyncPinImport") (EVar "driver")) (EApp (EApp (EVar "wrapEntryMain") (EApp (EVar "EVar") (EVar "asyncMainPinName"))) (EVar "decls"))))))
(DTypeSig false "synthLoc" (TyCon "Loc"))
(DFunDef false "synthLoc" () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "asyncPinImport" (TyFun (TyCon "EntryKey") (TyCon "Decl")))
(DFunDef false "asyncPinImport" ((PVar "driver")) (EApp (EApp (EApp (EVar "DUse") (EVar "False")) (EApp (EApp (EVar "UseGroup") (EApp (EApp (EVar "split") (ELit (LString "."))) (EFieldAccess (EVar "driver") "moduleId"))) (EListLit (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "asyncMainPinName")) (EVar "False")) (EVar "synthLoc")) (EVar "None"))))) (EVar "synthLoc")))
# MARK
(DUse false (UseGroup ("string") ((mem "split" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" false) (mem "Loc" true) (mem "UsePath" true) (mem "UseMember" true))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "mangledName" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcReport" true) (mem "CheckedProgram" true) (mem "EntryOutcome" true))))
(DUse false (UseGroup ("types" "program_facts") ((mem "ProgramFacts" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveInputs" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestSelector" true) (mem "ManifestRequirement" true) (mem "InvocationProtocol" true))))
(DTypeSig true "mainEntryKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EntryKey")))
(DFunDef false "mainEntryKey" ((PVar "modules")) (ERecordCreate "EntryKey" ((fa "moduleId" (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "Some" (PTuple (PVar "mid") PWild)) () (EVar "mid")) (arm (PCon "None") () (ELit (LString ""))))) (fa "binding" (ELit (LString "main"))))))
(DTypeSig true "executedMainInputs" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "EntryKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "DriveInputs")))))
(DFunDef false "executedMainInputs" ((PVar "inputs") (PVar "driver") (PVar "modules")) (ERecordUpdate (EVar "inputs") ((fa "diExecutedMainDriver" (EApp (EVar "Some") (EVar "driver"))) (fa "diManifestRequests" (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EIf (EApp (EVar "isSome") (EApp (EVar "findMainParams") (EVar "decls"))) (EBinOp "::" (EApp (EApp (EVar "ExactEntry") (EApp (EVar "mainEntryKey") (EVar "modules"))) (EVar "ExecutedMain")) (EFieldAccess (EVar "inputs") "diManifestRequests")) (EFieldAccess (EVar "inputs") "diManifestRequests"))) (arm (PCon "None") () (EFieldAccess (EVar "inputs") "diManifestRequests")))))))
(DTypeSig true "executedMainRequirement" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ManifestRequirement")))
(DFunDef false "executedMainRequirement" ((PVar "modules")) (EApp (EApp (EVar "CheckedEntry") (EApp (EVar "mainEntryKey") (EVar "modules"))) (EVar "ExecutedMain")))
(DTypeSig false "entryPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "entryPair" ((PList)) (EVar "None"))
(DFunDef false "entryPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "entryPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "entryPair") (EVar "rest")))
(DTypeSig false "findMainParams" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "findMainParams" ((PList)) (EVar "None"))
(DFunDef false "findMainParams" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "findMainParams") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findMainParams" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PVar "ps") PWild PWild PWild) PWild)) (EApp (EVar "Some") (EVar "ps")))
(DFunDef false "findMainParams" ((PCons PWild (PVar "rest"))) (EApp (EVar "findMainParams") (EVar "rest")))
(DTypeSig false "definesPrintln" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "definesPrintln" ((PList)) (EVar "False"))
(DFunDef false "definesPrintln" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "definesPrintln") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definesPrintln" ((PCons (PCon "DFunDef" PWild (PLit (LString "println")) PWild PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "definesPrintln" ((PCons PWild (PVar "rest"))) (EApp (EVar "definesPrintln") (EVar "rest")))
(DTypeSig true "shouldAutoPrintMain" (TyFun (TyCon "EntryOutcome") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool")))))
(DFunDef false "shouldAutoPrintMain" ((PVar "outcome") (PVar "coreDecls") (PVar "modules")) (EIf (EBinOp "||" (EFieldAccess (EVar "outcome") "eoMainIsUnit") (EFieldAccess (EVar "outcome") "eoMainIsAsync")) (EVar "False") (EApp (EApp (EVar "valueMainCandidate") (EVar "coreDecls")) (EVar "modules"))))
(DTypeSig true "valueMainCandidate" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool"))))
(DFunDef false "valueMainCandidate" ((PVar "coreDecls") (PVar "modules")) (EIf (EApp (EVar "not") (EApp (EVar "definesPrintln") (EBinOp "++" (EVar "coreDecls") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))))) (EVar "False") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EVar "True")) (arm PWild () (EVar "False")))))))
(DTypeSig false "isMainTypeSig" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isMainTypeSig" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isMainTypeSig") (EVar "d")))
(DFunDef false "isMainTypeSig" ((PCon "DTypeSig" PWild (PLit (LString "main")) PWild PWild)) (EVar "True"))
(DFunDef false "isMainTypeSig" (PWild) (EVar "False"))
(DTypeSig true "autoPrintPinName" (TyCon "String"))
(DFunDef false "autoPrintPinName" () (ELit (LString "0autoprintln")))
(DTypeSig true "autoPrintPinCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "autoPrintPinCore" ((PVar "coreDecls")) (EBinOp "++" (EVar "coreDecls") (EApp (EVar "pinnedPrintlnDecls") (EVar "coreDecls"))))
(DTypeSig false "pinnedPrintlnDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "pinnedPrintlnDecls" ((PVar "decls")) (EApp (EApp (EApp (EVar "pinnedCopies") (ELit (LString "println"))) (EVar "autoPrintPinName")) (EVar "decls")))
(DTypeSig false "pinnedCopies" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "pinnedCopies" (PWild PWild (PList)) (EListLit))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DTypeSig" PWild (PVar "n") (PVar "ty") (PVar "site")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DTypeSig") (EVar "True")) (EVar "pin")) (EVar "ty")) (EVar "site")) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PVar "site") (PVar "bid")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "origin")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "True")) (EVar "pin")) (EVar "ps")) (EVar "body")) (EVar "site")) (EVar "bid")) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest"))))
(DFunDef false "pinnedCopies" ((PVar "origin") (PVar "pin") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "pinnedCopies") (EVar "origin")) (EVar "pin")) (EVar "rest")))
(DTypeSig true "executedTrees" (TyFun (TyCon "EntryOutcome") (TyFun (TyCon "EntryKey") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "executedTrees" ((PVar "outcome") (PVar "driver") (PTuple (PVar "coreD") (PVar "modsD")) (PTuple (PVar "coreE") (PVar "modsE"))) (EIf (EApp (EApp (EApp (EVar "shouldAutoPrintMain") (EVar "outcome")) (EVar "coreD")) (EVar "modsD")) (EMatch (EFieldAccess (EVar "outcome") "eoAutoPrint") (arm (PCon "Some" (PVar "ev")) () (EApp (EVar "Ok") (ETuple (EApp (EVar "autoPrintPinCore") (EVar "coreE")) (EApp (EApp (EVar "onEntry") (EApp (EVar "wrapEntryMain") (EApp (EApp (EVar "EDictAt") (EVar "autoPrintPinName")) (EVar "ev")))) (EVar "modsE"))))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "internal error: the typecheck published no evidence for printing the value `main`"))))) (EIf (EApp (EApp (EApp (EVar "shouldAsyncWrapMain") (EVar "outcome")) (EVar "driver")) (EVar "modsD")) (EApp (EVar "Ok") (ETuple (EVar "coreE") (EApp (EApp (EVar "asyncWrapModules") (EVar "driver")) (EVar "modsE")))) (EApp (EVar "Ok") (ETuple (EVar "coreE") (EVar "modsE"))))))
(DTypeSig true "executedFromReport" (TyFun (TyCon "TcReport") (TyFun (TyCon "EntryKey") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "executedFromReport" ((PVar "report") (PVar "driver") (PVar "source")) (EMatch (EFieldAccess (EVar "report") "trChecked") (arm (PCon "Some" (PVar "checked")) () (EMatch (EFieldAccess (EVar "checked") "cpTrees") (arm (PCon "Some" (PVar "trees")) () (EApp (EApp (EApp (EApp (EVar "executedTrees") (EFieldAccess (EVar "checked") "cpEntryOutcome")) (EVar "driver")) (EVar "source")) (EVar "trees"))) (arm (PCon "None") () (EVar "noChecked")))) (arm (PCon "None") () (EVar "noChecked"))))
(DTypeSig false "noChecked" (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "noChecked" () (EApp (EVar "Err") (ELit (LString "internal error: the typecheck published no checked program to run"))))
(DTypeSig true "mainIsWrapped" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool")))
(DFunDef false "mainIsWrapped" ((PVar "modules")) (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EApp (EVar "wrappedMainIn") (EVar "decls"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "factsForExecutedTrees" (TyFun (TyCon "ProgramFacts") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ProgramFacts"))))
(DFunDef false "factsForExecutedTrees" ((PVar "facts") (PVar "modules")) (EIf (EApp (EVar "mainIsWrapped") (EVar "modules")) (ERecordUpdate (EVar "facts") ((fa "pfEntryOutcome" (EApp (EApp (EMethodRef "map") (EVar "executedEntryOutcome")) (EFieldAccess (EVar "facts") "pfEntryOutcome"))))) (EVar "facts")))
(DTypeSig false "executedEntryOutcome" (TyFun (TyCon "EntryOutcome") (TyCon "EntryOutcome")))
(DFunDef false "executedEntryOutcome" ((PVar "outcome")) (ERecordUpdate (EVar "outcome") ((fa "eoMainIsUnit" (EVar "True")) (fa "eoMainIsFloat" (EVar "False")) (fa "eoMainIsAsync" (EVar "False")) (fa "eoMainAsyncPayloadIsUnit" (EVar "False")) (fa "eoAutoPrint" (EVar "None")))))
(DTypeSig false "wrappedMainIn" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "wrappedMainIn" ((PList)) (EVar "False"))
(DFunDef false "wrappedMainIn" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "wrappedMainIn") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "wrappedMainIn" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PList) (PVar "body") PWild PWild) PWild)) (EApp (EVar "isWrapCall") (EVar "body")))
(DFunDef false "wrappedMainIn" ((PCons PWild (PVar "rest"))) (EApp (EVar "wrappedMainIn") (EVar "rest")))
(DTypeSig false "isWrapCall" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isWrapCall" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isWrapCall") (EVar "e")))
(DFunDef false "isWrapCall" ((PCon "EApp" (PCon "EDictAt" (PVar "n") PWild) PWild)) (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "autoPrintPinName")) (EBinOp "==" (EVar "n") (EApp (EApp (EVar "mangledName") (ELit (LString "core"))) (EVar "autoPrintPinName")))))
(DFunDef false "isWrapCall" ((PCon "EApp" (PCon "EVar" (PVar "n")) PWild)) (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "asyncMainPinName")) (EBinOp "==" (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "asyncModuleId")) (EVar "asyncMainPinName")))))
(DFunDef false "isWrapCall" (PWild) (EVar "False"))
(DTypeSig false "onEntry" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "onEntry" (PWild (PList)) (EListLit))
(DFunDef false "onEntry" ((PVar "f") (PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "f") (EVar "decls")))))
(DFunDef false "onEntry" ((PVar "f") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EApp (EVar "onEntry") (EVar "f")) (EVar "rest"))))
(DTypeSig false "wrapEntryMain" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "wrapEntryMain" ((PVar "callee") (PVar "decls")) (EApp (EApp (EMethodRef "map") (EApp (EVar "wrapMainDecl") (EVar "callee"))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isMainTypeSig") (EVar "d"))))) (EVar "decls"))))
(DTypeSig false "wrapMainDecl" (TyFun (TyCon "Expr") (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "wrapMainDecl" ((PVar "callee") (PCon "DFunDef" (PVar "vis") (PLit (LString "main")) (PList) (PVar "body") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (ELit (LString "main"))) (EListLit)) (EApp (EApp (EApp (EVar "wrapCall") (EVar "callee")) (EVar "site")) (EVar "body"))) (EVar "site")) (EVar "bid")))
(DFunDef false "wrapMainDecl" ((PVar "callee") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "a")) (EApp (EApp (EVar "wrapMainDecl") (EVar "callee")) (EVar "d"))))
(DFunDef false "wrapMainDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "wrapCall" (TyFun (TyCon "Expr") (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "wrapCall" ((PVar "callee") PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "EApp") (EVar "callee")) (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "inner")))))
(DFunDef false "wrapCall" ((PVar "callee") (PVar "site") (PVar "body")) (EApp (EApp (EVar "ELoc") (EVar "site")) (EApp (EApp (EVar "EApp") (EVar "callee")) (EVar "body"))))
(DTypeSig true "asyncMainPinName" (TyCon "String"))
(DFunDef false "asyncMainPinName" () (ELit (LString "0runasync")))
(DTypeSig false "asyncModuleId" (TyCon "String"))
(DFunDef false "asyncModuleId" () (ELit (LString "async")))
(DTypeSig true "shouldAsyncWrapMain" (TyFun (TyCon "EntryOutcome") (TyFun (TyCon "EntryKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool")))))
(DFunDef false "shouldAsyncWrapMain" ((PVar "outcome") (PVar "driver") (PVar "modules")) (EIf (EApp (EVar "not") (EBinOp "&&" (EFieldAccess (EVar "outcome") "eoMainIsAsync") (EFieldAccess (EVar "outcome") "eoMainAsyncPayloadIsUnit"))) (EVar "False") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EApp (EApp (EDictApp "any") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EFieldAccess (EVar "driver") "moduleId")) (EApp (EApp (EVar "definesFun") (EFieldAccess (EVar "driver") "binding")) (EApp (EVar "snd") (EVar "p")))))) (EVar "modules"))) (arm PWild () (EVar "False")))))))
(DTypeSig true "asyncMainShapeError" (TyFun (TyCon "EntryOutcome") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "asyncMainShapeError" ((PVar "outcome") (PVar "modules")) (EIf (EBinOp "||" (EApp (EVar "not") (EFieldAccess (EVar "outcome") "eoMainIsAsync")) (EFieldAccess (EVar "outcome") "eoMainAsyncPayloadIsUnit")) (EVar "None") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EApp (EVar "Some") (ELit (LString "main : Async e a must have a Unit payload (`main : Async e Unit`) — the driver runs the program for its effects and has nowhere to put a value; print it inside the program instead")))) (arm PWild () (EVar "None")))))))
(DTypeSig false "definesFun" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "definesFun" (PWild (PList)) (EVar "False"))
(DFunDef false "definesFun" ((PVar "n") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "definesFun") (EVar "n")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definesFun" ((PVar "n") (PCons (PCon "DFunDef" PWild (PVar "m") PWild PWild PWild PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EVar "True") (EApp (EApp (EVar "definesFun") (EVar "n")) (EVar "rest"))))
(DFunDef false "definesFun" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "definesFun") (EVar "n")) (EVar "rest")))
(DTypeSig true "asyncWrapModules" (TyFun (TyCon "EntryKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "asyncWrapModules" ((PVar "driver") (PVar "modules")) (EApp (EApp (EVar "wrapAsyncEntry") (EVar "driver")) (EApp (EApp (EMethodRef "map") (EApp (EVar "pinAsyncDriver") (EVar "driver"))) (EVar "modules"))))
(DTypeSig false "pinAsyncDriver" (TyFun (TyCon "EntryKey") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "pinAsyncDriver" ((PVar "driver") (PTuple (PVar "mid") (PVar "decls"))) (EIf (EBinOp "==" (EVar "mid") (EFieldAccess (EVar "driver") "moduleId")) (ETuple (EVar "mid") (EBinOp "++" (EVar "decls") (EApp (EApp (EApp (EVar "pinnedCopies") (EFieldAccess (EVar "driver") "binding")) (EVar "asyncMainPinName")) (EVar "decls")))) (ETuple (EVar "mid") (EVar "decls"))))
(DTypeSig false "wrapAsyncEntry" (TyFun (TyCon "EntryKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "wrapAsyncEntry" ((PVar "driver")) (EApp (EVar "onEntry") (ELam ((PVar "decls")) (EBinOp "::" (EApp (EVar "asyncPinImport") (EVar "driver")) (EApp (EApp (EVar "wrapEntryMain") (EApp (EVar "EVar") (EVar "asyncMainPinName"))) (EVar "decls"))))))
(DTypeSig false "synthLoc" (TyCon "Loc"))
(DFunDef false "synthLoc" () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "asyncPinImport" (TyFun (TyCon "EntryKey") (TyCon "Decl")))
(DFunDef false "asyncPinImport" ((PVar "driver")) (EApp (EApp (EApp (EVar "DUse") (EVar "False")) (EApp (EApp (EVar "UseGroup") (EApp (EApp (EVar "split") (ELit (LString "."))) (EFieldAccess (EVar "driver") "moduleId"))) (EListLit (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "asyncMainPinName")) (EVar "False")) (EVar "synthLoc")) (EVar "None"))))) (EVar "synthLoc")))
