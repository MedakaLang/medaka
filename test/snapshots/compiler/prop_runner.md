# META
source_lines=1650
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted property-test runner.
--
-- For each `prop "name" (x : T) (y : U) … = body` declaration: generate random
-- inputs for each parameter (structurally, from the type), evaluate the body in
-- an environment extended with those bindings, and check it returns True for
-- max_tests draws.  On the first failing draw, greedily shrink the
-- counterexample and report it.
--
-- Generation draws from this module's own private LCG (`rngNextLocal`), seeded
-- by `--seed`/`seedPropRng` and isolated from the program under test — it does
-- NOT go through eval.mdk's `randomInt`/`randomBool` externs, which use a
-- separate SplitMix64 generator for the program's own `random*` calls.  A
-- PASSING prop's output (`OK (100 tests)`) is RNG-independent, so it matches
-- `medaka test`.  A FAILING prop's shrunk counterexample is RNG-dependent and
-- diverges across all three runners — see the report in
-- test/diff_compiler_fmt_test.mdk's `testGoldenFailure`.

import frontend.ast.{
  Decl(..),
  Expr,
  PropParam,
  Ty(..),
}
import u32 as U32
import eval.eval.{
  Value(..), EvalEnv(..), apply, eval, extendEnv, force, lookupEnv,
  lookupRuntimeBinding, ppValue
}
import support.util.{listLen, lookupAssoc, isEmptyL, filterList, anyList}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omInsert, omLookup}
import tools.prop_plan.{
  deleteEach,
  prepend,
  prependBefore,
  PlanEnv(..),
  PlanError,
  PlanModule,
  TypeKey(..),
  GenPlan(..),
  CustomPlan(..),
  PlanDef(..),
  PlanCtor(..),
  PlanVisibility(..),
  planFor,
  planErrorText,
  planDef,
  instantiateCtor,
  buildPlanEnv,
  buildPlanEnvModules,
  listLengthBound,
  ctorWeights,
  optionWeights,
  resultWeights,
  intMin,
  intMax,
  customPlansReachable,
}

-- `medaka test --filter <substring>`: does `needle` occur anywhere in
-- `haystack`? Same tiny definition as `test_cmd.mdk`'s copy — not shared via
-- support/util.mdk to keep this slice's snapshot bless scoped to the files it
-- names.
substringMatch : String -> String -> Bool
substringMatch needle haystack = isSome (stringIndexOf needle haystack)

-- ── RNG wrappers (call the eval externs through tiny Medaka shims) ───────────
-- The externs are bound by name in the eval frame, but prop_runner runs OUTSIDE
-- the evaluated program — so we re-implement the same LCG draws here over a
-- PRIVATE ref (`propRngStateRef`), NOT `eval.mdk`'s `rngStateRef`.
--
-- #2295/#2316 F-4: `rngStateRef` is the SAME ref the evaluated program's own
-- `randomInt`/`randomBool` externs draw from — sharing it here would mean
-- `medaka test --seed <n>` perturbs the interpreter's supposedly-independent
-- random draws for a program under test, which contradicts the settled "the
-- interpreter is a pure deterministic oracle" decision (a --seed run of one
-- prop must not change what a DIFFERENT prop or the program itself draws).
-- Same initial value (123456789) as `rngStateRef`, so an UNSEEDED run is
-- byte-identical to before this split whenever the program under test makes no
-- random draws of its own (the overwhelming majority of props) — this is a
-- behavior-preserving refactor except for the exact perturbation case it closes.
propRngStateRef : Ref Int
propRngStateRef = Ref 123456789

propSeedRef : Ref Int
propSeedRef = Ref 123456789

-- Custom Arbitrary implementations run program code and may call random*. Keep
-- their full SplitMix64 state separate from both the law body and this runner's
-- structural LCG. A `(hi, lo)` pair is the evaluator representation of U64.
customRngStateRef : Ref (Int, Int)
customRngStateRef = Ref (0, 0)

customRngReadyRef : Ref Bool
customRngReadyRef = Ref False

customSeedRef : Ref Int
customSeedRef = Ref 123456789

-- `--seed <n>`: reseed the prop runner's own RNG before running. Never touches
-- `rngStateRef`. Only the draw state is reduced into `0 .. 2^31 - 1`, so
-- `rngNextLocal`'s multiply cannot overflow. Replay metadata retains the
-- original integer seed.
export
seedPropRng : Int -> Unit
seedPropRng n =
  let normalized = (n % 2147483648 + 2147483648) % 2147483648
  propRngStateRef := normalized
  propSeedRef := n
  customSeedRef := normalized
  customRngReadyRef := False

beginCustomPropStream : Int -> Unit
beginCustomPropStream seed =
  customSeedRef := seed
  customRngReadyRef := False

export
propSeedValue : Unit -> Int
propSeedValue _ = !propSeedRef

rngNextLocal : Unit -> Int
-- Odd multiplier and odd increment make bit `i` of consecutive `s` values
-- have period <= 2^(i+1) (Knuth), so ANY contiguous bit-window read straight
-- off `s` — including a shifted/truncated one — inherits a short period at
-- its own low end. A caller drawing many values (an 8-parameter prop can
-- draw hundreds) can exhaust a short-period window's whole range and still
-- silently miss most of the assignment space.
--
-- Run the raw state through a Murmur3-style `fmix32` finalizer instead: two
-- multiply/xor-shift rounds so every output bit depends nonlinearly on many
-- state bits (full avalanche), leaving no short-period window for a caller
-- to extract. The finalizer's words are `U32`, so each multiply wraps
-- modulo 2^32 as `fmix32` requires. The state stays an `Int` below 2^31, so
-- its advancement cannot overflow and `--seed` reproducibility is unaffected.
rngNextLocal _ =
  let s = (!propRngStateRef * 1103515245 + 12345) % 2147483648
  propRngStateRef := s
  let h1 = fromInt (bitXor s (shiftRight s 16)) : U32
  let h2 = h1 * 2246822507
  let h3 = U32.bitXor h2 (U32.shiftRight h2 13)
  let h4 = h3 * 3266489909
  U32.toInt (U32.bitXor h4 (U32.shiftRight h4 16))

randIntRange : Int -> Int -> Int
randIntRange lo hi =
  let range = hi - lo + 1
  if range <= 0 then lo else lo + rngNextLocal () % range

-- Exported so a distribution regression test can seed the runner's private
-- RNG (`seedPropRng`) and draw a raw sequence directly, without going through
-- a `prop`'s randomized-length `List Bool` generation.
export
randBoolL : Unit -> Bool
randBoolL _ = rngNextLocal () % 2 == 1

-- ── what a draw may consult ─────────────────────────────────────────────────
-- The shared PlanEnv makes every structural and capability decision. GenEnv
-- maps a selected custom carrier to compiler-typed helper bindings.
public export data PropHelper = PropHelper String String String
public export data GenEnv = GenEnv PlanEnv (OrdMap PropHelper)
export
buildGenEnv : List Decl -> List Decl -> GenEnv
buildGenEnv _ allDecls = GenEnv (buildPlanEnv allDecls) omEmpty

buildGenEnvWithPlan : List Decl -> PlanEnv -> GenEnv
buildGenEnvWithPlan _ planEnv = GenEnv planEnv omEmpty

export
buildGenEnvWithHelpers : List Decl -> PlanEnv -> List PropHelper -> GenEnv
buildGenEnvWithHelpers _ planEnv helpers =
  GenEnv planEnv (helperMap helpers omEmpty)

helperMap : List PropHelper -> OrdMap PropHelper -> OrdMap PropHelper
helperMap [] acc = acc
helperMap ((helper@(PropHelper word _ _)) :: rest) acc =
  helperMap rest (omInsert word helper acc)

genFloat : Unit -> <e> Value e
genFloat _ =
  let r = rngNextLocal () % 2000001
  VFloat (intToFloat r * (1.0 / 1000000.0) - 1.0)

genCharStr : Unit -> String
genCharStr _ = match charFromCode (32 + rngNextLocal () % 95)
  Some c => charToStr c
  None => " "

-- random String of printable ASCII, length 0..10
genString : Unit -> String
genString _ = stringConcat (genStringGo (randIntRange 0 10))

genStringGo : Int -> List String
genStringGo 0 = []
genStringGo n = genCharStr () :: genStringGo (n - 1)

shrinkInt : Int -> List (Value e)
shrinkInt 0 = []
shrinkInt n =
  let cands = [0, n / 2, n + (if n > 0 then -1 else 1)]
  map VInt (filterList (/= n) cands)

-- ── prop evaluation ──────────────────────────────────────────────────────────
-- evalEnv is the program's binding environment (List (String, Value)); each
-- prop body is evaluated in a frame extending it with the generated inputs.

checkProp : EvalEnv (Value e) -> Expr -> List (String, Value e) -> <e> Bool
checkProp rootEnv body inputs =
  let env = extendEnv rootEnv inputs
  match force (eval env body)
    VBool b => b
    _ => False

-- ── one prop run ─────────────────────────────────────────────────────────────

-- parameterized over the value type (v := Value e) — see the kind-inference
-- note on eval.mdk's `Value`
-- `PropFailed run shrunk fuelExhausted` — `fuelExhausted` is #1307's shrink
-- fuel cap firing: True means shrinkLoopFuel hit the cap before a shrink arm
-- returned None on its own, so `shrunk` may not be minimal and (per the
-- issue's own severity rule: loud->silent is a regression) that must be
-- reported on the same channel as the counterexample, not swallowed.
public export data PropOutcome v =
  | PropPassed
  | PropFailed Int (List (String, v)) Bool

-- #2293/#2295 (a): every prop's output now carries `file:line` — the same
-- caller-supplied line-lookup a `test "…"` decl uses (name-matched against a
-- POSITION-preserving reparse; test_cmd.mdk's `propLineTests`), since a
-- `DProp`'s elaborated body loses its ELoc the same way a DTest's does.  `0`
-- (name not found in the lookup) omits the location rather than printing a
-- misleading `:0`.
lineOfPropName : String -> List (String, Int) -> Int
lineOfPropName name propLines = match lookupAssoc name propLines
  Some l => l
  None => 0

propLocPrefix : String -> Int -> String
propLocPrefix _ 0 = ""
propLocPrefix target line = "\{target}:\{intToString line}: "

runProp : GenEnv ->
  List (String, Value e) ->
  Decl ->
  Int ->
  String ->
  List (String, Int) ->
  <IO | e> Bool
runProp genEnv evalEnv (DProp _ name params body) maxTests target propLines =
  let line = lineOfPropName name propLines
  let _ = putStr "\{propLocPrefix target line}Testing \{escStrLocal name} ... "
  -- #2295: capture the prop's OWN RNG state at the moment it starts drawing
  -- (before any generation for this prop happens) — reseeding to this exact
  -- value via `--seed` reproduces this prop's draws byte-for-byte regardless
  -- of what ran before it, so it is the number to print on failure.
  let seedAtStart = !propRngStateRef
  let rootEnv = extendEnv (EvalEnv [[]]) evalEnv
  match planPropParams (genEnvPlan genEnv) name params
    Err e =>
      let _ = putStrLn ("ERROR: " ++ planErrorText e)
      False
    Ok plans => match helperFailure genEnv rootEnv plans
      Some detail =>
        let _ = putStrLn ("ERROR: " ++ detail)
        False
      None =>
        let _ = beginCustomPropStream seedAtStart
        match findFailure genEnv rootEnv params body maxTests 1
          PropPassed =>
            let _ = putStrLn ("OK (" ++ intToString maxTests ++ " tests)")
            True
          PropFailed run shrunk fuelExhausted =>
            let _ =
              putStrLn
                "FAILED after \{intToString run}\{if run == 1 then " test" else " tests"}"
            let _ =
              if fuelExhausted then
                putStrLn
                  "  WARNING: shrink fuel exhausted after \{intToString shrinkFuel} steps; the counterexample below may not be minimal, and a shrink arm is probably cycling (see #1307)."
            let _ =
              putStrLn
                "  Seed: \{intToString seedAtStart} (rerun with: medaka test --seed \{intToString seedAtStart} --filter \{escStrLocal name} <file>)"
            let _ = putStrLn "  Counterexample:"
            let _ = printCounterexample shrunk
            False
runProp _genEnv _evalEnv _decl _maxTests _target _propLines = True

findFailure : GenEnv ->
  EvalEnv (Value e) ->
  List PropParam ->
  Expr ->
  Int ->
  Int ->
  <e> PropOutcome (Value e)
findFailure genEnv evalEnv params body maxTests run
  | run > maxTests = PropPassed
  | otherwise =
    let inputs = genInputs genEnv evalEnv params
    findFailureStep
      genEnv
      evalEnv
      params
      body
      maxTests
      run
      inputs
      (checkProp evalEnv body inputs)

findFailurePlanned : GenEnv ->
  EvalEnv (Value e) ->
  List PropParam ->
  List GenPlan ->
  Expr ->
  Int ->
  Int ->
  <e> PropOutcome (Value e)
findFailurePlanned genEnv evalEnv params plans body maxTests run
  | run > maxTests = PropPassed
  | otherwise =
    let inputs = genInputsPlanned genEnv evalEnv params plans
    if checkProp evalEnv body inputs then
      findFailurePlanned genEnv evalEnv params plans body maxTests (run + 1)
    else
      let (shrunk, fuelExhausted) = shrinkLoop genEnv evalEnv params body inputs
      PropFailed run shrunk fuelExhausted

findFailureStep : GenEnv ->
  EvalEnv (Value e) ->
  List PropParam ->
  Expr ->
  Int ->
  Int ->
  List (String, Value e) ->
  Bool ->
  <e> PropOutcome (Value e)
findFailureStep genEnv evalEnv params body maxTests run _ True =
  findFailure genEnv evalEnv params body maxTests (run + 1)
findFailureStep genEnv evalEnv params body _ run inputs False =
  let (shrunk, fuelExhausted) = shrinkLoop genEnv evalEnv params body inputs
  PropFailed run shrunk fuelExhausted

genInputs : GenEnv ->
  EvalEnv (Value e) ->
  List PropParam ->
  <e> List (String, Value e)
genInputs _ _ [] = []
genInputs genEnv evalEnv ((PropParam x _ ty) :: rest) =
  (x, genParam genEnv evalEnv ty) :: genInputs genEnv evalEnv rest

genInputsPlanned : GenEnv ->
  EvalEnv (Value e) ->
  List PropParam ->
  List GenPlan ->
  <e> List (String, Value e)
genInputsPlanned _ _ [] [] = []
genInputsPlanned genEnv evalEnv ((PropParam x _ _) :: rest) (plan :: plans) =
  (x, genFromPlan genEnv evalEnv 0 plan)
    :: genInputsPlanned genEnv evalEnv rest plans
genInputsPlanned _ _ _ _ =
  panic "property runner: prepared parameter plan mismatch"

genParam : GenEnv -> EvalEnv (Value e) -> Ty -> <e> Value e
genParam (ge@(GenEnv planEnv _)) evalEnv ty =
  match planFor planEnv "" "property parameter" ty
    Ok plan => genFromPlan ge evalEnv 0 plan
    Err e => panic (planErrorText e)

-- Interpret the same finite plan the native runner renders. Imported nominals
-- resolve through PlanEnv by TypeKey, never through a spelling-only registry.
genFromPlan : GenEnv -> EvalEnv (Value e) -> Int -> GenPlan -> <e> Value e
genFromPlan _ _ _ GInt = VInt (randIntRange intMin intMax)
genFromPlan _ _ _ GBool = VBool (randBoolL ())
genFromPlan _ _ _ GFloat = genFloat ()
genFromPlan _ _ _ GChar = VChar (genCharStr ())
genFromPlan _ _ _ GString = VString (genString ())
genFromPlan _ _ _ GUnit = VUnit
genFromPlan ge env depth (GList plan) =
  VList
    (genPlanList
      ge
      env
      depth
      plan
      (randIntRange 0 (listLengthBound (genEnvPlan ge) depth plan)))
genFromPlan ge env depth (GArray plan) =
  VArray
    (arrayFromList
      (genPlanList
        ge
        env
        depth
        plan
        (randIntRange 0 (listLengthBound (genEnvPlan ge) depth plan))))
genFromPlan ge env depth (GOption plan) =
  chooseOption ge env depth plan (optionWeights (genEnvPlan ge) depth plan)
genFromPlan ge env depth (GResult err ok) =
  chooseResult ge env depth err ok (resultWeights (genEnvPlan ge) depth err ok)
genFromPlan ge env depth (GTuple plans) =
  VTuple (map (genFromPlan ge env depth) plans)
genFromPlan ge env depth (nominal@(GNominal key _)) =
  match planDef (genEnvPlan ge) key
    Ok (PlanDef _ _ _ _ ctors) =>
      genPlannedCtor
        ge
        env
        depth
        nominal
        (choosePlanCtor ctors (ctorWeights (genEnvPlan ge) nominal depth))
    Err e => panic (planErrorText e)
genFromPlan ge env _ (custom@(GCustom _)) = drawCustomArbitrary ge env custom

genEnvPlan : GenEnv -> PlanEnv
genEnvPlan (GenEnv planEnv _) = planEnv

-- Swap the evaluated program's complete U64 RNG state around one custom draw.
-- `randomState`/`restoreRandomState` are invoked through the same evaluator
-- environment as the property, so this keeps all three engines' public RNG
-- contract rather than reaching into an interpreter-global ref.
drawCustomArbitrary : GenEnv -> EvalEnv (Value e) -> GenPlan -> <e> Value e
drawCustomArbitrary ge env custom =
  let programState = readRandomState env
  let _ = ensureCustomRandomState env
  let (hi, lo) = !customRngStateRef
  let _ = restoreRandomStateValue env (VU64 hi lo)
  let value = match customHelper ge custom
    Some (PropHelper _ genName _) =>
      force (apply (force (lookupEnv env genName)) VUnit)
    None => panic "property runner: missing selected typed custom helper"
  let customState = readRandomState env
  customRngStateRef := u64Pair customState
  let _ = restoreRandomStateValue env programState
  value

customHelper : GenEnv -> GenPlan -> Option PropHelper
customHelper (GenEnv _ helpers) (GCustom (CustomPlan _ _ word)) =
  omLookup word helpers
customHelper _ _ = None

-- Before a property starts, validate every helper the selected plans can call.
-- A caller may therefore return a normal protocol/runtime result rather than
-- entering generation and tripping an evaluator panic for an absent helper.
helperFailure : GenEnv -> EvalEnv (Value e) -> List GenPlan -> Option String
helperFailure ge env plans =
  helperFailureCustoms
    ge
    (envBindingNames env)
    (customPlansReachable (genEnvPlan ge) plans)

helperFailureCustoms : GenEnv -> OrdMap Unit -> List CustomPlan -> Option String
helperFailureCustoms _ _ [] = None
helperFailureCustoms ge names (custom :: rest) =
  match customHelper ge (GCustom custom)
    Some (PropHelper _ genName shrinkName) => match (
      omHasKey genName names,
      omHasKey shrinkName names,
    )
      (True, True) => helperFailureCustoms ge names rest
      _ => Some "selected typed custom helper binding is unavailable"
    None => Some "selected typed custom helper is unavailable"

-- This deliberately records names only: validating helpers must observe the
-- caller's original cells without forcing or rebuilding its root environment.
envBindingNames : EvalEnv (Value e) -> OrdMap Unit
envBindingNames (EvalEnv frames) = bindingNamesFrames frames omEmpty

bindingNamesFrames : List (List (String, Ref (Value e))) ->
  OrdMap Unit ->
  OrdMap Unit
bindingNamesFrames [] names = names
bindingNamesFrames (frame :: rest) names =
  bindingNamesFrames rest (bindingNamesFrame frame names)

bindingNamesFrame : List (String, Ref (Value e)) -> OrdMap Unit -> OrdMap Unit
bindingNamesFrame [] names = names
bindingNamesFrame ((name, _) :: rest) names =
  bindingNamesFrame rest (omInsert name () names)

ensureCustomRandomState : EvalEnv (Value e) -> <e> Unit
ensureCustomRandomState env =
  if !customRngReadyRef then
    ()
  else
    let programState = readRandomState env
    let _ = callRandomSetSeed env !customSeedRef
    let seeded = readRandomState env
    customRngStateRef := u64Pair seeded
    let _ = restoreRandomStateValue env programState
    customRngReadyRef := True

readRandomState : EvalEnv (Value e) -> <e> Value e
readRandomState env =
  force (apply (force (lookupRuntimeBinding env "randomState")) VUnit)

restoreRandomStateValue : EvalEnv (Value e) -> Value e -> <e> Unit
restoreRandomStateValue env state =
  match (force
    (apply (force (lookupRuntimeBinding env "restoreRandomState")) state))
    VUnit => ()
    _ => panic "property runner: restoreRandomState returned a non-Unit value"

callRandomSetSeed : EvalEnv (Value e) -> Int -> <e> Unit
callRandomSetSeed env seed =
  match force (apply (force (lookupRuntimeBinding env "setSeed")) (VInt seed))
    VUnit => ()
    _ => panic "property runner: setSeed returned a non-Unit value"

u64Pair : Value e -> (Int, Int)
u64Pair (VU64 hi lo) = (hi, lo)
u64Pair _ = panic "property runner: randomState returned a non-U64 value"

genPlanList : GenEnv ->
  EvalEnv (Value e) ->
  Int ->
  GenPlan ->
  Int ->
  <e> List (Value e)
genPlanList _ _ _ _ 0 = []
genPlanList ge env depth plan n =
  genFromPlan ge env depth plan :: genPlanList ge env depth plan (n - 1)

chooseOption : GenEnv ->
  EvalEnv (Value e) ->
  Int ->
  GenPlan ->
  List Int ->
  <e> Value e
chooseOption ge env depth plan weights =
  if chooseWeight weights then
    VCon "None" []
  else
    VCon "Some" [genFromPlan ge env depth plan]

chooseResult : GenEnv ->
  EvalEnv (Value e) ->
  Int ->
  GenPlan ->
  GenPlan ->
  List Int ->
  <e> Value e
chooseResult ge env depth err ok weights =
  if chooseWeight weights then
    VCon "Err" [genFromPlan ge env depth err]
  else
    VCon "Ok" [genFromPlan ge env depth ok]

-- All branch and constructor weights originate in prop_plan. A zero total is
-- an internal invariant breach: planFor has already established a finite path.
chooseWeight : List Int -> Bool
chooseWeight (first :: second :: _) =
  let total = first + second
  if total <= 0 then
    panic "property runner: planner produced no finite branch"
  else
    randIntRange 0 (total - 1) < first
chooseWeight _ =
  panic "property runner: planner returned malformed branch weights"

choosePlanCtor : List PlanCtor -> List Int -> PlanCtor
choosePlanCtor [] _ = panic "property runner: nominal type has no constructors"
choosePlanCtor ctors weights =
  let total = sumWeights weights
  if total <= 0 then
    panic "property runner: planner produced no finite constructor"
  else
    choosePlanCtorAt ctors weights (randIntRange 0 (total - 1))

choosePlanCtorAt : List PlanCtor -> List Int -> Int -> PlanCtor
choosePlanCtorAt (ctor :: _) [] _ = ctor
choosePlanCtorAt (ctor :: _) (weight :: _) n
  | n < weight = ctor
choosePlanCtorAt (_ :: ctors) (weight :: weights) n =
  choosePlanCtorAt ctors weights (n - weight)
choosePlanCtorAt [] _ _ =
  panic "property runner: constructor weights were empty"

sumWeights : List Int -> Int
sumWeights [] = 0
sumWeights (n :: rest) = n + sumWeights rest

nthList : List a -> Int -> a
nthList (x :: _) 0 = x
nthList (_ :: rest) n = nthList rest (n - 1)
nthList [] _ = panic "property runner: index out of range"

genPlannedCtor : GenEnv ->
  EvalEnv (Value e) ->
  Int ->
  GenPlan ->
  PlanCtor ->
  <e> Value e
genPlannedCtor ge env depth nominal (ctor@(PlanCtor _ runtime _)) =
  match instantiateCtor (genEnvPlan ge) nominal ctor
    Ok fields =>
      plannedCtorValue runtime (genPlannedFields ge env (depth + 1) fields)
    Err e => panic (planErrorText e)

genPlannedFields : GenEnv ->
  EvalEnv (Value e) ->
  Int ->
  List (Option String, GenPlan) ->
  <e> List (Option String, Value e)
genPlannedFields _ _ _ [] = []
genPlannedFields ge env depth ((name, plan) :: rest) =
  (name, genFromPlan ge env depth plan) :: genPlannedFields ge env depth rest

plannedCtorValue : String -> List (Option String, Value e) -> Value e
plannedCtorValue runtime [] = VCon runtime []
plannedCtorValue runtime ((Some name, value) :: rest) =
  VRecord runtime ((name, value) :: namedPlanFields rest)
plannedCtorValue runtime ((None, value) :: rest) =
  VCon runtime (value :: positionalPlanFields rest)

namedPlanFields : List (Option String, Value e) -> List (String, Value e)
namedPlanFields [] = []
namedPlanFields ((Some name, value) :: rest) =
  (name, value) :: namedPlanFields rest
namedPlanFields ((None, _) :: _) =
  panic "property runner: mixed positional and named constructor fields"

positionalPlanFields : List (Option String, Value e) -> List (Value e)
positionalPlanFields [] = []
positionalPlanFields ((None, value) :: rest) =
  value :: positionalPlanFields rest
positionalPlanFields ((Some _, _) :: _) =
  panic "property runner: mixed positional and named constructor fields"

shrinkForParam : GenEnv ->
  EvalEnv (Value e) ->
  Ty ->
  Value e ->
  <e> List (Value e)
shrinkForParam ge env ty value =
  match planFor (genEnvPlan ge) "" "property parameter" ty
    Ok (custom@(GCustom _)) => match customHelper ge custom
      Some (PropHelper _ _ shrinkName) =>
        match force (apply (force (lookupEnv env shrinkName)) value)
          VList smaller => smaller
          _ =>
            panic
              "property runner: typed custom shrink returned a non-List value"
      None => panic "property runner: missing selected typed custom helper"
    Ok plan => structuralShrink ge env plan value
    Err e => panic (planErrorText e)

shrinkCustom : GenEnv ->
  EvalEnv (Value e) ->
  GenPlan ->
  Value e ->
  <e> List (Value e)
shrinkCustom ge env custom value = match customHelper ge custom
  Some (PropHelper _ _ shrinkName) =>
    match force (apply (force (lookupEnv env shrinkName)) value)
      VList smaller => smaller
      _ =>
        panic "property runner: typed custom shrink returned a non-List value"
  None => panic "property runner: missing selected typed custom helper"

-- Interpret the planner's structural order for evaluator values.  The action
-- algebra supplies deletion/child ordering; constructor replacement is kept
-- ahead of fields, so native and eval take the same greedy path.
structuralShrink : GenEnv ->
  EvalEnv (Value e) ->
  GenPlan ->
  Value e ->
  <e> List (Value e)
structuralShrink _ _ GInt (VInt n) = shrinkInt n
structuralShrink _ _ GBool (VBool True) = [VBool False]
structuralShrink _ _ GBool _ = []
structuralShrink _ _ GFloat (VFloat x) =
  if x == 0.0 then [] else [VFloat 0.0, VFloat (x / 2.0)]
structuralShrink _ _ GString (VString s) =
  if s == "" then [] else [VString (stringSlice 0 (stringLength s / 2) s)]
structuralShrink _ _ GChar (VChar _) = []
structuralShrink _ _ GUnit _ = []
structuralShrink ge env (GList plan) (VList values) =
  map VList (deleteEach values) ++ map VList (shrinkElements ge env plan values)
structuralShrink ge env (GArray plan) (VArray values) =
  let xs = toList values
  map (xs2 => VArray (arrayFromList xs2)) (deleteEach xs)
    ++ map (xs2 => VArray (arrayFromList xs2)) (shrinkElements ge env plan xs)
structuralShrink ge env (GOption plan) (VCon "Some" [value]) =
  VCon "None" []
    :: map (v => VCon "Some" [v]) (structuralShrink ge env plan value)
structuralShrink _ _ (GOption _) _ = []
structuralShrink ge env (GResult err _) (VCon "Err" [value]) =
  map (v => VCon "Err" [v]) (structuralShrink ge env err value)
structuralShrink ge env (GResult _ ok) (VCon "Ok" [value]) =
  map (v => VCon "Ok" [v]) (structuralShrink ge env ok value)
structuralShrink _ _ (GResult _ _) _ = []
structuralShrink ge env (GTuple plans) (VTuple values) =
  map VTuple (shrinkPlanValues ge env plans values)
structuralShrink ge env (nominal@(GNominal key _)) value =
  shrinkNominal ge env nominal key value
structuralShrink ge env (custom@(GCustom _)) value =
  shrinkCustom ge env custom value
structuralShrink _ _ _ _ = []

shrinkElements : GenEnv ->
  EvalEnv (Value e) ->
  GenPlan ->
  List (Value e) ->
  <e> List (List (Value e))
shrinkElements _ _ _ [] = []
shrinkElements ge env plan (value :: values) =
  let here = map (prependBefore values) (structuralShrink ge env plan value)
  here ++ map (prepend value) (shrinkElements ge env plan values)

shrinkPlanValues : GenEnv ->
  EvalEnv (Value e) ->
  List GenPlan ->
  List (Value e) ->
  <e> List (List (Value e))
shrinkPlanValues _ _ [] _ = []
shrinkPlanValues _ _ _ [] = []
shrinkPlanValues ge env (plan :: plans) (value :: values) =
  map (prependBefore values) (structuralShrink ge env plan value)
    ++ map (prepend value) (shrinkPlanValues ge env plans values)

shrinkNominal : GenEnv ->
  EvalEnv (Value e) ->
  GenPlan ->
  TypeKey ->
  Value e ->
  <e> List (Value e)
shrinkNominal ge env nominal key value = match planDef (genEnvPlan ge) key
  Ok (PlanDef _ _ _ _ ctors) =>
    nullaryCtorValues ctors ++ shrinkNominalFields ge env nominal ctors value
  Err _ => []

nullaryCtorValues : List PlanCtor -> List (Value e)
nullaryCtorValues [] = []
nullaryCtorValues ((PlanCtor _ runtime []) :: rest) =
  VCon runtime [] :: nullaryCtorValues rest
nullaryCtorValues (_ :: rest) = nullaryCtorValues rest

shrinkNominalFields : GenEnv ->
  EvalEnv (Value e) ->
  GenPlan ->
  List PlanCtor ->
  Value e ->
  <e> List (Value e)
shrinkNominalFields ge env nominal ctors (VCon runtime values) =
  match planCtorRuntime runtime ctors
    Some ctor => match instantiateCtor (genEnvPlan ge) nominal ctor
      Ok fields =>
        map
          (vs => VCon runtime vs)
          (shrinkPlanValues ge env (fieldPlans fields) values)
      Err _ => []
    None => []
shrinkNominalFields ge env nominal ctors (VRecord runtime fields) =
  match planCtorRuntime runtime ctors
    Some ctor => match instantiateCtor (genEnvPlan ge) nominal ctor
      Ok plans =>
        map
          (vs => VRecord runtime (zipNames (fieldNames fields) vs))
          (shrinkPlanValues ge env (fieldPlans plans) (fieldValues fields))
      Err _ => []
    None => []
shrinkNominalFields _ _ _ _ _ = []

planCtorRuntime : String -> List PlanCtor -> Option PlanCtor
planCtorRuntime _ [] = None
planCtorRuntime runtime ((ctor@(PlanCtor _ actual _)) :: rest) =
  if runtime == actual then Some ctor else planCtorRuntime runtime rest

fieldPlans : List (Option String, GenPlan) -> List GenPlan
fieldPlans [] = []
fieldPlans ((_, plan) :: rest) = plan :: fieldPlans rest

fieldNames : List (String, Value e) -> List String
fieldNames [] = []
fieldNames ((name, _) :: rest) = name :: fieldNames rest

fieldValues : List (String, Value e) -> List (Value e)
fieldValues [] = []
fieldValues ((_, value) :: rest) = value :: fieldValues rest

zipNames : List String -> List (Value e) -> List (String, Value e)
zipNames [] _ = []
zipNames _ [] = []
zipNames (name :: names) (value :: values) =
  (name, value) :: zipNames names values

printCounterexample : List (String, Value e) -> <IO> Unit
printCounterexample [] = ()
printCounterexample ((x, v) :: rest) =
  let _ = putStrLn "    \{x} = \{ppValue v}"
  printCounterexample rest

escStrLocal : String -> String
escStrLocal s = "\"" ++ s ++ "\""

-- ── greedy shrink ───────────────────────────────────────────────────────────

-- Fuel cap: defense-in-depth against a future shrink arm reintroducing a
-- non-decreasing candidate (as `shrinkInt` did before this cap existed — see
-- #1307). A correct arm never comes close to this many steps; if one ever
-- cycles again, shrinking now stops and reports the best candidate found so
-- far instead of hanging forever.
shrinkFuel : Int
shrinkFuel = 10000

-- Returns (candidate, fuelExhausted) rather than printing directly:
-- shrinkLoop/shrinkLoopFuel stay effect-POLYMORPHIC (<e>, whatever the prop
-- body under test performs — NOT necessarily <IO>), mirroring every other
-- helper in this shrink chain (tryShrinkOne, findSmaller, checkProp all call
-- `eval`, whose effect is the tested program's, not this tool's). Forcing
-- <IO> here to print inline broke that polymorphism (a concrete effect
-- can't be woven into an otherwise-generalized recursive effect variable —
-- confirmed: `test_main` failed to typecheck with "declared with <> but
-- also performs <IO>" when tried). The exhaustion flag is instead reported
-- by the caller, `runProp`, which is unconditionally <IO> already.
shrinkLoop : GenEnv ->
  EvalEnv (Value e) ->
  List PropParam ->
  Expr ->
  List (String, Value e) ->
  <e> (List (String, Value e), Bool)
shrinkLoop genEnv evalEnv params body candidate =
  shrinkLoopFuel genEnv evalEnv params body candidate shrinkFuel

shrinkLoopFuel : GenEnv ->
  EvalEnv (Value e) ->
  List PropParam ->
  Expr ->
  List (String, Value e) ->
  Int ->
  <e> (List (String, Value e), Bool)
shrinkLoopFuel _ _ _ _ candidate 0 = (candidate, True)
shrinkLoopFuel genEnv evalEnv params body candidate fuel =
  match tryShrinkOne genEnv evalEnv params body candidate 0
    Some better => shrinkLoopFuel genEnv evalEnv params body better (fuel - 1)
    None => (candidate, False)

-- Try each param in order; return the first candidate where some smaller value
-- still fails the prop.
tryShrinkOne : GenEnv ->
  EvalEnv (Value e) ->
  List PropParam ->
  Expr ->
  List (String, Value e) ->
  Int ->
  <e> Option (List (String, Value e))
tryShrinkOne genEnv evalEnv params body candidate i
  | i >= listLen params = None
  | otherwise =
    let (PropParam x _ ty) = nthList params i
    let currentV = assocVal x candidate
    let smaller = shrinkForParam genEnv evalEnv ty currentV
    match findSmaller evalEnv params body candidate x smaller
      Some better => Some better
      None => tryShrinkOne genEnv evalEnv params body candidate (i + 1)

findSmaller : EvalEnv (Value e) ->
  List PropParam ->
  Expr ->
  List (String, Value e) ->
  String ->
  List (Value e) ->
  <e> Option (List (String, Value e))
findSmaller _ _ _ _ _ [] = None
findSmaller evalEnv params body candidate x (sv :: rest) =
  let candidate2 = replaceVal x sv candidate
  if checkProp evalEnv body candidate2 then
    findSmaller evalEnv params body candidate x rest
  else
    Some candidate2

assocVal : String -> List (String, Value e) -> Value e
assocVal x kvs = match lookupAssoc x kvs
  Some v => v
  None => panic ("prop shrink: missing binding " ++ x)

replaceVal : String ->
  Value e ->
  List (String, Value e) ->
  List (String, Value e)
replaceVal _ _ [] = []
replaceVal x sv ((k, v) :: rest)
  | k == x = (k, sv) :: replaceVal x sv rest
  | otherwise = (k, v) :: replaceVal x sv rest

-- ── run all props in a program ───────────────────────────────────────────────

isProp : Decl -> Bool
isProp (DProp _ _ _ _) = True
isProp _ = False

export
filterProps : List Decl -> List Decl
filterProps decls = filterDecls isProp decls

filterDecls : (Decl -> Bool) -> List Decl -> List Decl
filterDecls _ [] = []
filterDecls p (d :: rest)
  | p d = d :: filterDecls p rest
  | otherwise = filterDecls p rest

-- `medaka test --filter <substring>` (#2295): keep only props whose name
-- contains `substring`. `None` (no `--filter` given) is a no-op.
export
filterPropsByName : Option String -> List Decl -> List Decl
filterPropsByName None decls = decls
filterPropsByName (Some sub) decls = filterDecls (propNameMatches sub) decls

propNameMatches : String -> Decl -> Bool
propNameMatches sub (DProp _ name _ _) = substringMatch sub name
propNameMatches _ _ = False

-- Run every prop; print the trailing summary; return True iff all passed.
-- Output: no leading line; one
-- `Testing … OK/FAILED` per prop; a blank line then `N passed, M failed`.
-- `cases` overrides the hardcoded 100-draw sample count (`medaka test --cases
-- <n>`, #2295); `filterOpt` restricts to props whose name contains a
-- substring (`--filter`).
-- `target`/`propLines` (#2293/#2295 (a)): the file path and a name-keyed
-- line lookup (test_cmd.mdk's `propLineTests`) so every prop's output carries
-- `file:line` — see `runProp`.
export
runAllProps : Int ->
  Option String ->
  String ->
  List (String, Int) ->
  List (String, Value e) ->
  List Decl ->
  List Decl ->
  <IO | e> Bool
runAllProps cases filterOpt target propLines evalEnv program allDecls =
  let props = filterPropsByName filterOpt (filterProps program)
  if isEmptyL props then
    True
  else
    let genEnv = buildGenEnv program allDecls
    let results = runEach cases target propLines genEnv evalEnv props
    let nPass = countTrue results
    let nFail = listLen results - nPass
    let _ =
      putStrLn "\n\{intToString nPass} passed, \{intToString nFail} failed"
    nFail == 0

runEach : Int ->
  String ->
  List (String, Int) ->
  GenEnv ->
  List (String, Value e) ->
  List Decl ->
  <IO | e> List Bool
runEach _ _ _ _ _ [] = []
runEach cases target propLines genEnv evalEnv (p :: rest) =
  runProp genEnv evalEnv p cases target propLines
    :: runEach cases target propLines genEnv evalEnv rest

countTrue : List Bool -> Int
countTrue [] = 0
countTrue (True :: rest) = 1 + countTrue rest
countTrue (False :: rest) = countTrue rest

-- ── structured (non-printing) results — for `medaka mcp`'s medaka_test (#252) ──
-- Mirror runAllProps' discovery + per-prop `findFailure`, but return a plain,
-- effect-free `PropResult` per prop instead of PRINTING.  The human `medaka test`
-- path (runAllProps above) is untouched — this is a parallel, silent reporter.
-- ⚠️ A PASSING prop's detail is deterministic ("100 tests"); a FAILING prop's
-- shrunk counterexample is RNG-dependent and diverges across the three runners
-- (see the module header), so a consumer must treat the counterexample text as
-- non-portable — do not bake a failing-prop counterexample into a golden.
-- The engine is data rather than an ambient CLI label: the JSON/MCP consumers
-- must not silently present an interpreter result as a native result when a
-- caller asks for both engines.
public export data PropStatus =
  | PropPassedResult
  | PropFailedResult
  | PropErroredResult

public export data PropFailureKind =
  | PropLawFalse
  | PropCapabilityError
  | PropBuildError
  | PropRuntimeError
  | PropProtocolError
  | PropTypeError

public export data PropRequest = PropRequest String Int Int

export
propRequestName : PropRequest -> String
propRequestName (PropRequest name _ _) = name

export
propRequestSeed : PropRequest -> Int
propRequestSeed (PropRequest _ seed _) = seed

export
propRequestCases : PropRequest -> Int
propRequestCases (PropRequest _ _ cases) = cases

public export data PropResult =
  | PropResult String String PropStatus (Option PropFailureKind) String Int Int
--                                          name   ok   detail

public export data PreparedPropRequest =
  | PreparedRun PropRequest Decl (List GenPlan)
  | PreparedResult PropResult

export
propResultName : PropResult -> String
propResultName (PropResult _ n _ _ _ _ _) = n

export
propResultEngine : PropResult -> String
propResultEngine (PropResult e _ _ _ _ _ _) = e

export
propResultPassed : PropResult -> Bool
propResultPassed (PropResult _ _ PropPassedResult _ _ _ _) = True
propResultPassed _ = False

export
propResultDetail : PropResult -> String
propResultDetail (PropResult _ _ _ _ d _ _) = d

export
propResultStatus : PropResult -> PropStatus
propResultStatus (PropResult _ _ s _ _ _ _) = s

export
propResultFailureKind : PropResult -> Option PropFailureKind
propResultFailureKind (PropResult _ _ _ kind _ _ _) = kind

export
propResultSeed : PropResult -> Int
propResultSeed (PropResult _ _ _ _ _ seed _) = seed

export
propResultCases : PropResult -> Int
propResultCases (PropResult _ _ _ _ _ _ cases) = cases

-- Run every prop and return one PropResult each, in source order.  No output.
-- Same `cases`/`filterOpt` knobs as `runAllProps` (F-3: both hardcoded-100
-- sites move together, or `--cases` would silently affect only the human
-- `medaka test` path and not this structured/MCP one).
-- `propLines` (#2293/#2295 (a)): threaded into `PropResult`'s failing-case
-- detail string the same way `runProp` threads it into its printed output —
-- see `lineOfPropName`.  No file path here: this structured path (medaka
-- mcp's medaka_test, and `medaka test --json`) already reports `file` once
-- at the top level, so only the line is folded into `detail`.
export
runAllPropsResults : Int ->
  Option String ->
  List (String, Int) ->
  List (String, Value e) ->
  List Decl ->
  List Decl ->
  <e> List PropResult
runAllPropsResults cases filterOpt propLines evalEnv program allDecls =
  let props = filterPropsByName filterOpt (filterProps program)
  let rootEnv = extendEnv (EvalEnv [[]]) evalEnv
  if isEmptyL props then
    []
  else
    runEachResult
      cases
      propLines
      (buildGenEnv program allDecls)
      evalEnv
      rootEnv
      props

-- Request-driven structured execution is the command layer's raw contract.  A
-- pin may supply its own replay seed and case budget, so deriving these from a
-- process-global default would make a known-red witness non-reproducible.  The
-- request list is therefore authoritative and its order (including duplicates)
-- is preserved.  A declaration name is NOT an identity: duplicate root names
-- are a protocol error for every matching request, never "first one wins".
export
runAllPropRequestsResults : List PropRequest ->
  List (String, Int) ->
  List (String, Value e) ->
  List Decl ->
  List Decl ->
  <e> List PropResult
runAllPropRequestsResults requests propLines evalEnv program allDecls =
  runPropRequests
    requests
    propLines
    (buildGenEnv program allDecls)
    evalEnv
    (filterProps program)

-- The command path supplies the paired raw/elaborated graph retained by its
-- loader.  Keep the historical entry above for direct callers, while making
-- identity/visibility decisions from the graph rather than a spelling scan.
export
runAllPlannedPropRequestsResults : String ->
  List PlanModule ->
  List PropRequest ->
  List (String, Int) ->
  EvalEnv (Value e) ->
  List Decl ->
  <e> List PropResult
runAllPlannedPropRequestsResults root modules requests propLines evalEnv program =
  match buildPlanEnvModules root modules
    Ok planEnv =>
      runPropRequestsInEnv
        requests
        propLines
        (buildGenEnvWithPlan (runtimeModuleDecls modules) planEnv)
        evalEnv
        (filterProps program)
    Err err => map (requestPlanError err) requests

export
preparePlannedPropRequests : String ->
  List PlanModule ->
  List PropRequest ->
  List Decl ->
  Result PlanError (PlanEnv, List PreparedPropRequest)
preparePlannedPropRequests root modules requests rootProps =
  map
    (env =>
      (env, prepareRequests env requests requests (filterProps rootProps)))
    (buildPlanEnvModules root modules)

prepareRequests : PlanEnv ->
  List PropRequest ->
  List PropRequest ->
  List Decl ->
  List PreparedPropRequest
prepareRequests _ _ [] _ = []
prepareRequests env all ((request@(PropRequest name seed cases)) :: rest) props =
  let row =
    if requestNameRepeated name all then
      PreparedResult (duplicateRequest name seed cases)
    else if cases <= 0 then
      PreparedResult
        (PropResult
          "eval"
          name
          PropErroredResult
          (Some PropProtocolError)
          "property request has a non-positive case count"
          seed
          cases)
    else match propsNamed name props
      [decl@(DProp _ _ params _)] => match planPropParams env name params
        Ok plans => PreparedRun request decl plans
        Err e => PreparedResult (capabilityResult name seed cases e)
      [] => PreparedResult (missingRequest request)
      _ =>
        PreparedResult
          (PropResult
            "eval"
            name
            PropErroredResult
            (Some PropProtocolError)
            "property request is ambiguous: the root module declares '{name}' more than once"
            seed
            cases)
  row :: prepareRequests env all rest props

export
runPreparedPropRequestsResults : PlanEnv ->
  List PropHelper ->
  List PreparedPropRequest ->
  List (String, Int) ->
  EvalEnv (Value e) ->
  List Decl ->
  <e> List PropResult
runPreparedPropRequestsResults planEnv helpers rows propLines evalEnv runtimeDecls =
  runPreparedRows
    (buildGenEnvWithHelpers runtimeDecls planEnv helpers)
    rows
    propLines
    evalEnv

runPreparedRows : GenEnv ->
  List PreparedPropRequest ->
  List (String, Int) ->
  EvalEnv (Value e) ->
  <e> List PropResult
runPreparedRows _ [] _ _ = []
runPreparedRows genEnv ((PreparedResult result) :: rest) propLines evalEnv =
  result :: runPreparedRows genEnv rest propLines evalEnv
runPreparedRows genEnv ((PreparedRun (PropRequest name seed cases) (DProp _ _ params body) plans) :: rest) propLines evalEnv =
  let _ = seedPropRng seed
  (match helperFailure genEnv evalEnv plans
      Some detail => runtimeResult name seed cases detail
      None =>
        let _ = beginCustomPropStream seed
        propResultOf
          (genEnvPlan genEnv)
          plans
          cases
          seed
          (lineOfPropName name propLines)
          name
          (findFailurePlanned genEnv evalEnv params plans body cases 1))
    :: runPreparedRows genEnv rest propLines evalEnv
runPreparedRows genEnv (_ :: rest) propLines evalEnv =
  runPreparedRows genEnv rest propLines evalEnv

export
runAllPlannedPropRequestsWithHelpersResults : String ->
  List PlanModule ->
  List PropHelper ->
  List PropRequest ->
  List (String, Int) ->
  EvalEnv (Value e) ->
  List Decl ->
  <e> List PropResult
runAllPlannedPropRequestsWithHelpersResults root modules helpers requests propLines evalEnv program =
  match buildPlanEnvModules root modules
    Ok planEnv =>
      runPropRequestsInEnv
        requests
        propLines
        (buildGenEnvWithHelpers (runtimeModuleDecls modules) planEnv helpers)
        evalEnv
        (filterProps program)
    Err err => map (requestPlanError err) requests

runtimeModuleDecls : List PlanModule -> List Decl
runtimeModuleDecls [] = []
runtimeModuleDecls ((PlanModule _ _ runtime) :: rest) =
  runtime ++ runtimeModuleDecls rest

requestPlanError : PlanError -> PropRequest -> PropResult
requestPlanError err (PropRequest name seed cases) =
  capabilityResult name seed cases err

runPropRequests : List PropRequest ->
  List (String, Int) ->
  GenEnv ->
  List (String, Value e) ->
  List Decl ->
  <e> List PropResult
runPropRequests requests propLines genEnv evalEnv props =
  let rootEnv = extendEnv (EvalEnv [[]]) evalEnv
  runPropRequestsChecked
    requests
    requests
    propLines
    genEnv
    evalEnv
    rootEnv
    props

runPropRequestsInEnv : List PropRequest ->
  List (String, Int) ->
  GenEnv ->
  EvalEnv (Value e) ->
  List Decl ->
  <e> List PropResult
runPropRequestsInEnv requests propLines genEnv rootEnv props =
  runPropRequestsChecked requests requests propLines genEnv [] rootEnv props

runPropRequestsChecked : List PropRequest ->
  List PropRequest ->
  List (String, Int) ->
  GenEnv ->
  List (String, Value e) ->
  EvalEnv (Value e) ->
  List Decl ->
  <e> List PropResult
runPropRequestsChecked _ [] _ _ _ _ _ = []
runPropRequestsChecked all ((request@(PropRequest name seed cases)) :: rest) propLines genEnv evalEnv rootEnv props =
  let result =
    if requestNameRepeated name all then
      duplicateRequest name seed cases
    else
      runPropRequest request propLines genEnv evalEnv rootEnv props
  result
    :: runPropRequestsChecked all rest propLines genEnv evalEnv rootEnv props

requestNameRepeated : String -> List PropRequest -> Bool
requestNameRepeated name requests = requestNameCount name requests > 1

requestNameCount : String -> List PropRequest -> Int
requestNameCount _ [] = 0
requestNameCount name ((PropRequest actual _ _) :: rest) =
  (if name == actual then 1 else 0) + requestNameCount name rest

duplicateRequest : String -> Int -> Int -> PropResult
duplicateRequest name seed cases =
  PropResult
    "eval"
    name
    PropErroredResult
    (Some PropProtocolError)
    "property request names '{name}' more than once"
    seed
    cases

runPropRequest : PropRequest ->
  List (String, Int) ->
  GenEnv ->
  List (String, Value e) ->
  EvalEnv (Value e) ->
  List Decl ->
  <e> PropResult
runPropRequest (request@(PropRequest name seed cases)) propLines genEnv evalEnv rootEnv props =
  let matches = propsNamed name props
  if cases <= 0 then
    PropResult
      "eval"
      name
      PropErroredResult
      (Some PropProtocolError)
      "property request has a non-positive case count"
      seed
      cases
  else if listLen matches == 1 then
    let _ = seedPropRng seed
    match matches
      [DProp _ _ params body] =>
        match planPropParams (genEnvPlan genEnv) name params
          Err e => capabilityResult name seed cases e
          Ok plans => match helperFailure genEnv rootEnv plans
            Some detail => runtimeResult name seed cases detail
            None =>
              let _ = beginCustomPropStream seed
              propResultOf
                (genEnvPlan genEnv)
                plans
                cases
                seed
                (lineOfPropName name propLines)
                name
                (findFailure genEnv rootEnv params body cases 1)
      _ => missingRequest request
  else if listLen matches == 0 then
    missingRequest request
  else
    PropResult
      "eval"
      name
      PropErroredResult
      (Some PropProtocolError)
      "property request is ambiguous: the root module declares '\{name}' more than once"
      seed
      cases

propsNamed : String -> List Decl -> List Decl
propsNamed _ [] = []
propsNamed wanted ((d@(DProp _ name _ _)) :: rest)
  | wanted == name = d :: propsNamed wanted rest
  | otherwise = propsNamed wanted rest
propsNamed wanted (_ :: rest) = propsNamed wanted rest

missingRequest : PropRequest -> PropResult
missingRequest (PropRequest name seed cases) =
  PropResult
    "eval"
    name
    PropErroredResult
    (Some PropProtocolError)
    "property request names no root declaration '\{name}'"
    seed
    cases

runEachResult : Int ->
  List (String, Int) ->
  GenEnv ->
  List (String, Value e) ->
  EvalEnv (Value e) ->
  List Decl ->
  <e> List PropResult
runEachResult _ _ _ _ _ [] = []
runEachResult cases propLines genEnv evalEnv rootEnv ((DProp _ name params body) :: rest) =
  let seedAtStart = !propRngStateRef
  (match planPropParams (genEnvPlan genEnv) name params
      Err e => capabilityResult name seedAtStart cases e
      Ok plans => match helperFailure genEnv rootEnv plans
        Some detail => runtimeResult name seedAtStart cases detail
        None =>
          let _ = beginCustomPropStream seedAtStart
          propResultOf
            (genEnvPlan genEnv)
            plans
            cases
            seedAtStart
            (lineOfPropName name propLines)
            name
            (findFailure genEnv rootEnv params body cases 1))
    :: runEachResult cases propLines genEnv evalEnv rootEnv rest
runEachResult cases propLines genEnv evalEnv rootEnv (_ :: rest) =
  runEachResult cases propLines genEnv evalEnv rootEnv rest

planPropParams : PlanEnv ->
  String ->
  List PropParam ->
  Result PlanError (List GenPlan)
planPropParams _ _ [] = Ok []
planPropParams planEnv propName ((PropParam param _ ty) :: rest) = match (
  planFor planEnv propName param ty,
  planPropParams planEnv propName rest,
)
  (Ok plan, Ok plans) => Ok (plan :: plans)
  (Err e, _) => Err e
  (_, Err e) => Err e

capabilityResult : String -> Int -> Int -> PlanError -> PropResult
capabilityResult name seed cases err =
  PropResult
    "eval"
    name
    PropErroredResult
    (Some PropCapabilityError)
    (planErrorText err)
    seed
    cases

runtimeResult : String -> Int -> Int -> String -> PropResult
runtimeResult name seed cases detail =
  PropResult
    "eval"
    name
    PropErroredResult
    (Some PropRuntimeError)
    detail
    seed
    cases
propResultOf : PlanEnv ->
  List GenPlan ->
  Int ->
  Int ->
  Int ->
  String ->
  PropOutcome (Value e) ->
  PropResult
propResultOf _ _ cases seed _line name PropPassed =
  PropResult
    "eval"
    name
    PropPassedResult
    None
    "\{intToString cases} tests passed"
    seed
    cases
propResultOf planEnv plans cases seed line name (PropFailed run shrunk fuelExhausted) =
  PropResult
    "eval"
    name
    PropFailedResult
    (Some PropLawFalse)
    (stringConcat [
      lineDetailPrefix line,
      "failed after ",
      intToString run,
      if run == 1 then
        " test; counterexample: "
      else
        " tests; counterexample: ",
      renderCounterexample planEnv plans shrunk,
      if fuelExhausted then
        " (WARNING: shrink fuel exhausted, counterexample may not be minimal — see #1307)"
      else
        "",
    ])
    seed
    cases

lineDetailPrefix : Int -> String
lineDetailPrefix 0 = ""
lineDetailPrefix line = "line \{intToString line}: "

renderCounterexample : PlanEnv ->
  List GenPlan ->
  List (String, Value e) ->
  String
renderCounterexample _ _ [] = ""
renderCounterexample env (plan :: plans) [(name, value)] =
  "\{name} = \{renderPlanValue env plan value}"
renderCounterexample env (plan :: plans) ((name, value) :: rest) = stringConcat
  [
    name,
    " = ",
    renderPlanValue env plan value,
    ", ",
    renderCounterexample env plans rest,
  ]
renderCounterexample _ _ [(name, _)] = name ++ " = <unplanned>"
renderCounterexample env [] ((name, _) :: rest) =
  "\{name} = <unplanned>, \{renderCounterexample env [] rest}"

renderPlanValue : PlanEnv -> GenPlan -> Value e -> String
renderPlanValue _ GInt value = ppValue value
renderPlanValue _ GBool (VBool True) = "True"
renderPlanValue _ GBool (VBool False) = "False"
renderPlanValue _ GBool value = ppValue value
renderPlanValue _ GFloat value = ppValue value
renderPlanValue _ GChar value = ppValue value
renderPlanValue _ GString value = ppValue value
renderPlanValue _ GUnit value = ppValue value
renderPlanValue env (GList plan) (VList values) =
  "[" ++ renderPlanValues env plan values ++ "]"
renderPlanValue env (GArray plan) (VArray values) =
  "[" ++ renderPlanValues env plan (arrayValues values) ++ "]"
renderPlanValue _ (GOption _) (VCon "None" []) = "None"
renderPlanValue env (GOption plan) (VCon "Some" [value]) =
  "Some(" ++ renderPlanValue env plan value ++ ")"
renderPlanValue env (GResult err _) (VCon "Err" [value]) =
  "Err(" ++ renderPlanValue env err value ++ ")"
renderPlanValue env (GResult _ ok) (VCon "Ok" [value]) =
  "Ok(" ++ renderPlanValue env ok value ++ ")"
renderPlanValue env (GTuple plans) (VTuple values) =
  "(" ++ renderPlanValuePairs env plans values ++ ")"
renderPlanValue env (nominal@(GNominal key _)) value =
  renderNominalValue env nominal key value
renderPlanValue env (GCustom (CustomPlan key carrier _)) value =
  match displayCarrierPlans env (carrierArgs carrier)
    Some args => renderNominalValue env (GNominal key args) key value
    None => hiddenType key
renderPlanValue _ _ _ = "<value>"

renderPlanValues : PlanEnv -> GenPlan -> List (Value e) -> String
renderPlanValues _ _ [] = ""
renderPlanValues env plan [value] = renderPlanValue env plan value
renderPlanValues env plan (value :: rest) =
  "\{renderPlanValue env plan value}, \{renderPlanValues env plan rest}"

arrayValues : Array a -> List a
arrayValues values = arrayValuesGo values 0 (arrayLength values)

arrayValuesGo : Array a -> Int -> Int -> List a
arrayValuesGo _ index size
  | index >= size = []
arrayValuesGo values index size =
  arrayGetUnsafe index values :: arrayValuesGo values (index + 1) size

renderPlanValuePairs : PlanEnv -> List GenPlan -> List (Value e) -> String
renderPlanValuePairs _ [] [] = ""
renderPlanValuePairs env (plan :: plans) (value :: values) =
  let rendered = renderPlanValue env plan value
  if isEmptyL plans || isEmptyL values then
    rendered
  else
    "\{rendered}, \{renderPlanValuePairs env plans values}"
renderPlanValuePairs _ _ _ = "<value>"

renderNominalValue : PlanEnv -> GenPlan -> TypeKey -> Value e -> String
renderNominalValue env nominal key value = match planDef env key
  Ok (PlanDef _ owner _ visibility ctors) =>
    if nominalVisible env owner visibility then
      renderVisibleNominal env nominal key ctors value
    else
      hiddenType key
  Err _ => hiddenType key

nominalVisible : PlanEnv -> String -> PlanVisibility -> Bool
nominalVisible _ _ PlanPublicCtors = True
nominalVisible (PlanEnv root _ _ _ _) owner PlanLocal = owner == root
nominalVisible (PlanEnv root _ _ _ _) owner PlanAbstract = owner == root

hiddenType : TypeKey -> String
hiddenType (TypeKey name _) = "<" ++ name ++ ">"

renderVisibleNominal : PlanEnv ->
  GenPlan ->
  TypeKey ->
  List PlanCtor ->
  Value e ->
  String
renderVisibleNominal env nominal key ctors (VCon runtime values) =
  match runtimeCtor runtime ctors
    Some ctor => match instantiateCtor env nominal ctor
      Ok fields => renderPositionalCtor env ctor fields values
      Err _ => hiddenType key
    None => hiddenType key
renderVisibleNominal env nominal key ctors (VRecord runtime values) =
  match runtimeCtor runtime ctors
    Some ctor => match instantiateCtor env nominal ctor
      Ok fields => renderNamedCtor env ctor fields values
      Err _ => hiddenType key
    None => hiddenType key
renderVisibleNominal _ _ key _ _ = hiddenType key

runtimeCtor : String -> List PlanCtor -> Option PlanCtor
runtimeCtor _ [] = None
runtimeCtor runtime ((ctor@(PlanCtor _ actual _)) :: rest)
  | runtime == actual = Some ctor
  | otherwise = runtimeCtor runtime rest

renderPositionalCtor : PlanEnv ->
  PlanCtor ->
  List (Option String, GenPlan) ->
  List (Value e) ->
  String
renderPositionalCtor env (PlanCtor source _ _) fields values =
  "\{source}(\{renderFields env fields values})"

renderNamedCtor : PlanEnv ->
  PlanCtor ->
  List (Option String, GenPlan) ->
  List (String, Value e) ->
  String
renderNamedCtor env (PlanCtor source _ _) fields values =
  "\{source} { \{renderNamedFields env fields values} }"

renderFields : PlanEnv ->
  List (Option String, GenPlan) ->
  List (Value e) ->
  String
renderFields _ [] [] = ""
renderFields env ((_, plan) :: plans) (value :: values) =
  let rendered = renderPlanValue env plan value
  if isEmptyL plans || isEmptyL values then
    rendered
  else
    "\{rendered}, \{renderFields env plans values}"
renderFields _ _ _ = "<value>"

renderNamedFields : PlanEnv ->
  List (Option String, GenPlan) ->
  List (String, Value e) ->
  String
renderNamedFields _ [] _ = ""
renderNamedFields env ((Some name, plan) :: rest) values =
  match lookupAssoc name values
    Some value =>
      let rendered = "\{name} = \{renderPlanValue env plan value}"
      if isEmptyL rest then
        rendered
      else
        "\{rendered}, \{renderNamedFields env rest values}"
    None => name ++ " = <value>"
renderNamedFields _ ((None, _) :: _) _ = "<value>"

carrierArgs : Ty -> List Ty
carrierArgs carrier = carrierArgsGo [] carrier

carrierArgsGo : List Ty -> Ty -> List Ty
carrierArgsGo acc (TyApp head arg) = carrierArgsGo (arg :: acc) head
carrierArgsGo acc _ = acc

displayCarrierPlans : PlanEnv -> List Ty -> Option (List GenPlan)
displayCarrierPlans _ [] = Some []
displayCarrierPlans env (ty :: rest) = match (
  planFor env "" "display" ty,
  displayCarrierPlans env rest,
)
  (Ok plan, Some plans) => Some (plan :: plans)
  _ => None

export
hasProps : List Decl -> Bool
hasProps decls = anyDecl isProp decls

anyDecl : (Decl -> Bool) -> List Decl -> Bool
anyDecl _ [] = False
anyDecl p (d :: rest) = p d || anyDecl p rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" false) (mem "PropParam" false) (mem "Ty" true))))
(DUse false (UseAlias ("u32") "U32"))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "apply" false) (mem "eval" false) (mem "extendEnv" false) (mem "force" false) (mem "lookupEnv" false) (mem "lookupRuntimeBinding" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "lookupAssoc" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "anyList" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("tools" "prop_plan") ((mem "deleteEach" false) (mem "prepend" false) (mem "prependBefore" false) (mem "PlanEnv" true) (mem "PlanError" false) (mem "PlanModule" false) (mem "TypeKey" true) (mem "GenPlan" true) (mem "CustomPlan" true) (mem "PlanDef" true) (mem "PlanCtor" true) (mem "PlanVisibility" true) (mem "planFor" false) (mem "planErrorText" false) (mem "planDef" false) (mem "instantiateCtor" false) (mem "buildPlanEnv" false) (mem "buildPlanEnvModules" false) (mem "listLengthBound" false) (mem "ctorWeights" false) (mem "optionWeights" false) (mem "resultWeights" false) (mem "intMin" false) (mem "intMax" false) (mem "customPlansReachable" false))))
(DTypeSig false "substringMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substringMatch" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig false "propRngStateRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "propRngStateRef" () (EApp (EVar "Ref") (ELit (LInt 123456789))))
(DTypeSig false "propSeedRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "propSeedRef" () (EApp (EVar "Ref") (ELit (LInt 123456789))))
(DTypeSig false "customRngStateRef" (TyApp (TyCon "Ref") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "customRngStateRef" () (EApp (EVar "Ref") (ETuple (ELit (LInt 0)) (ELit (LInt 0)))))
(DTypeSig false "customRngReadyRef" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "customRngReadyRef" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "customSeedRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "customSeedRef" () (EApp (EVar "Ref") (ELit (LInt 123456789))))
(DTypeSig true "seedPropRng" (TyFun (TyCon "Int") (TyCon "Unit")))
(DFunDef false "seedPropRng" ((PVar "n")) (EBlock (DoLet false false (PVar "normalized") (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (ELit (LInt 2147483648))) (ELit (LInt 2147483648))) (ELit (LInt 2147483648)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "propRngStateRef")) (EVar "normalized"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "propSeedRef")) (EVar "n"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customSeedRef")) (EVar "normalized"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customRngReadyRef")) (EVar "False")))))
(DTypeSig false "beginCustomPropStream" (TyFun (TyCon "Int") (TyCon "Unit")))
(DFunDef false "beginCustomPropStream" ((PVar "seed")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "customSeedRef")) (EVar "seed"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customRngReadyRef")) (EVar "False")))))
(DTypeSig true "propSeedValue" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "propSeedValue" (PWild) (EUnOp "!" (EVar "propSeedRef")))
(DTypeSig false "rngNextLocal" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "rngNextLocal" (PWild) (EBlock (DoLet false false (PVar "s") (EBinOp "%" (EBinOp "+" (EBinOp "*" (EUnOp "!" (EVar "propRngStateRef")) (ELit (LInt 1103515245))) (ELit (LInt 12345))) (ELit (LInt 2147483648)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "propRngStateRef")) (EVar "s"))) (DoLet false false (PVar "h1") (EAnnot (EApp (EVar "fromInt") (EApp (EApp (EVar "bitXor") (EVar "s")) (EApp (EApp (EVar "shiftRight") (EVar "s")) (ELit (LInt 16))))) (TyCon "U32"))) (DoLet false false (PVar "h2") (EBinOp "*" (EVar "h1") (ELit (LInt 2246822507)))) (DoLet false false (PVar "h3") (EApp (EApp (EVar "U32.bitXor") (EVar "h2")) (EApp (EApp (EVar "U32.shiftRight") (EVar "h2")) (ELit (LInt 13))))) (DoLet false false (PVar "h4") (EBinOp "*" (EVar "h3") (ELit (LInt 3266489909)))) (DoExpr (EApp (EVar "U32.toInt") (EApp (EApp (EVar "U32.bitXor") (EVar "h4")) (EApp (EApp (EVar "U32.shiftRight") (EVar "h4")) (ELit (LInt 16))))))))
(DTypeSig false "randIntRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "randIntRange" ((PVar "lo") (PVar "hi")) (EBlock (DoLet false false (PVar "range") (EBinOp "+" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<=" (EVar "range") (ELit (LInt 0))) (EVar "lo") (EBinOp "+" (EVar "lo") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (EVar "range")))))))
(DTypeSig true "randBoolL" (TyFun (TyCon "Unit") (TyCon "Bool")))
(DFunDef false "randBoolL" (PWild) (EBinOp "==" (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2))) (ELit (LInt 1))))
(DData Public "PropHelper" () ((variant "PropHelper" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DData Public "GenEnv" () ((variant "GenEnv" (ConPos (TyCon "PlanEnv") (TyApp (TyCon "OrdMap") (TyCon "PropHelper"))))) ())
(DTypeSig true "buildGenEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "GenEnv"))))
(DFunDef false "buildGenEnv" (PWild (PVar "allDecls")) (EApp (EApp (EVar "GenEnv") (EApp (EVar "buildPlanEnv") (EVar "allDecls"))) (EVar "omEmpty")))
(DTypeSig false "buildGenEnvWithPlan" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "PlanEnv") (TyCon "GenEnv"))))
(DFunDef false "buildGenEnvWithPlan" (PWild (PVar "planEnv")) (EApp (EApp (EVar "GenEnv") (EVar "planEnv")) (EVar "omEmpty")))
(DTypeSig true "buildGenEnvWithHelpers" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyCon "GenEnv")))))
(DFunDef false "buildGenEnvWithHelpers" (PWild (PVar "planEnv") (PVar "helpers")) (EApp (EApp (EVar "GenEnv") (EVar "planEnv")) (EApp (EApp (EVar "helperMap") (EVar "helpers")) (EVar "omEmpty"))))
(DTypeSig false "helperMap" (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "PropHelper")) (TyApp (TyCon "OrdMap") (TyCon "PropHelper")))))
(DFunDef false "helperMap" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "helperMap" ((PCons (PAs "helper" (PCon "PropHelper" (PVar "word") PWild PWild)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "helperMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "helper")) (EVar "acc"))))
(DTypeSig false "genFloat" (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "genFloat" (PWild) (EBlock (DoLet false false (PVar "r") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2000001)))) (DoExpr (EApp (EVar "VFloat") (EBinOp "-" (EBinOp "*" (EApp (EVar "intToFloat") (EVar "r")) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 1000000.0)))) (ELit (LFloat 1.0)))))))
(DTypeSig false "genCharStr" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genCharStr" (PWild) (EMatch (EApp (EVar "charFromCode") (EBinOp "+" (ELit (LInt 32)) (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 95))))) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "charToStr") (EVar "c"))) (arm (PCon "None") () (ELit (LString " ")))))
(DTypeSig false "genString" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genString" (PWild) (EApp (EVar "stringConcat") (EApp (EVar "genStringGo") (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (ELit (LInt 10))))))
(DTypeSig false "genStringGo" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "genStringGo" ((PLit (LInt 0))) (EListLit))
(DFunDef false "genStringGo" ((PVar "n")) (EBinOp "::" (EApp (EVar "genCharStr") (ELit LUnit)) (EApp (EVar "genStringGo") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "shrinkInt" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "shrinkInt" ((PLit (LInt 0))) (EListLit))
(DFunDef false "shrinkInt" ((PVar "n")) (EBlock (DoLet false false (PVar "cands") (EListLit (ELit (LInt 0)) (EBinOp "/" (EVar "n") (ELit (LInt 2))) (EBinOp "+" (EVar "n") (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "map") (EVar "VInt")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "n")))) (EVar "cands"))))))
(DTypeSig false "checkProp" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "checkProp" ((PVar "rootEnv") (PVar "body") (PVar "inputs")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "extendEnv") (EVar "rootEnv")) (EVar "inputs"))) (DoExpr (EMatch (EApp (EVar "force") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))) (arm (PCon "VBool" (PVar "b")) () (EVar "b")) (arm PWild () (EVar "False"))))))
(DData Public "PropOutcome" ("v") ((variant "PropPassed" (ConPos)) (variant "PropFailed" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "v"))) (TyCon "Bool")))) ())
(DTypeSig false "lineOfPropName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int"))))
(DFunDef false "lineOfPropName" ((PVar "name") (PVar "propLines")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "propLines")) (arm (PCon "Some" (PVar "l")) () (EVar "l")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "propLocPrefix" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "propLocPrefix" (PWild (PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "propLocPrefix" ((PVar "target") (PVar "line")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))))
(DTypeSig false "runProp" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyEffect ("IO") (Some "e") (TyCon "Bool")))))))))
(DFunDef false "runProp" ((PVar "genEnv") (PVar "evalEnv") (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "maxTests") (PVar "target") (PVar "propLines")) (EBlock (DoLet false false (PVar "line") (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "propLocPrefix") (EVar "target")) (EVar "line")))) (ELit (LString "Testing "))) (EApp (EVar "display") (EApp (EVar "escStrLocal") (EVar "name")))) (ELit (LString " ... "))))) (DoLet false false (PVar "seedAtStart") (EUnOp "!" (EVar "propRngStateRef"))) (DoLet false false (PVar "rootEnv") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EVar "evalEnv"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "planPropParams") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "name")) (EVar "params")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "ERROR: ")) (EApp (EVar "planErrorText") (EVar "e"))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "plans")) () (EMatch (EApp (EApp (EApp (EVar "helperFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "plans")) (arm (PCon "Some" (PVar "detail")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "ERROR: ")) (EVar "detail")))) (DoExpr (EVar "False")))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "beginCustomPropStream") (EVar "seedAtStart"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (ELit (LInt 1))) (arm (PCon "PropPassed") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "OK (")) (EApp (EVar "intToString") (EVar "maxTests"))) (ELit (LString " tests)"))))) (DoExpr (EVar "True")))) (arm (PCon "PropFailed" (PVar "run") (PVar "shrunk") (PVar "fuelExhausted")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAILED after ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "run")))) (ELit (LString ""))) (EApp (EVar "display") (EIf (EBinOp "==" (EVar "run") (ELit (LInt 1))) (ELit (LString " test")) (ELit (LString " tests"))))) (ELit (LString ""))))) (DoLet false false PWild (EIf (EVar "fuelExhausted") (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "  WARNING: shrink fuel exhausted after ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "shrinkFuel")))) (ELit (LString " steps; the counterexample below may not be minimal, and a shrink arm is probably cycling (see #1307).")))) (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  Seed: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "seedAtStart")))) (ELit (LString " (rerun with: medaka test --seed "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "seedAtStart")))) (ELit (LString " --filter "))) (EApp (EVar "display") (EApp (EVar "escStrLocal") (EVar "name")))) (ELit (LString " <file>)"))))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  Counterexample:")))) (DoLet false false PWild (EApp (EVar "printCounterexample") (EVar "shrunk"))) (DoExpr (EVar "False"))))))))))))))
(DFunDef false "runProp" ((PVar "_genEnv") (PVar "_evalEnv") (PVar "_decl") (PVar "_maxTests") (PVar "_target") (PVar "_propLines")) (EVar "True"))
(DTypeSig false "findFailure" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "findFailure" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run")) (EIf (EBinOp ">" (EVar "run") (EVar "maxTests")) (EVar "PropPassed") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "inputs") (EApp (EApp (EApp (EVar "genInputs") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailureStep") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EVar "run")) (EVar "inputs")) (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "inputs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findFailurePlanned" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e"))))))))))))
(DFunDef false "findFailurePlanned" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "plans") (PVar "body") (PVar "maxTests") (PVar "run")) (EIf (EBinOp ">" (EVar "run") (EVar "maxTests")) (EVar "PropPassed") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "inputs") (EApp (EApp (EApp (EApp (EVar "genInputsPlanned") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "plans"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "inputs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailurePlanned") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "plans")) (EVar "body")) (EVar "maxTests")) (EBinOp "+" (EVar "run") (ELit (LInt 1)))) (EBlock (DoLet false false (PTuple (PVar "shrunk") (PVar "fuelExhausted")) (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoop") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "inputs"))) (DoExpr (EApp (EApp (EApp (EVar "PropFailed") (EVar "run")) (EVar "shrunk")) (EVar "fuelExhausted"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findFailureStep" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Bool") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "findFailureStep" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run") PWild (PCon "True")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EBinOp "+" (EVar "run") (ELit (LInt 1)))))
(DFunDef false "findFailureStep" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") PWild (PVar "run") (PVar "inputs") (PCon "False")) (EBlock (DoLet false false (PTuple (PVar "shrunk") (PVar "fuelExhausted")) (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoop") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "inputs"))) (DoExpr (EApp (EApp (EApp (EVar "PropFailed") (EVar "run")) (EVar "shrunk")) (EVar "fuelExhausted")))))
(DTypeSig false "genInputs" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genInputs" (PWild PWild (PList)) (EListLit))
(DFunDef false "genInputs" ((PVar "genEnv") (PVar "evalEnv") (PCons (PCon "PropParam" (PVar "x") PWild (PVar "ty")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "x") (EApp (EApp (EApp (EVar "genParam") (EVar "genEnv")) (EVar "evalEnv")) (EVar "ty"))) (EApp (EApp (EApp (EVar "genInputs") (EVar "genEnv")) (EVar "evalEnv")) (EVar "rest"))))
(DTypeSig false "genInputsPlanned" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "genInputsPlanned" (PWild PWild (PList) (PList)) (EListLit))
(DFunDef false "genInputsPlanned" ((PVar "genEnv") (PVar "evalEnv") (PCons (PCon "PropParam" (PVar "x") PWild PWild) (PVar "rest")) (PCons (PVar "plan") (PVar "plans"))) (EBinOp "::" (ETuple (EVar "x") (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "genEnv")) (EVar "evalEnv")) (ELit (LInt 0))) (EVar "plan"))) (EApp (EApp (EApp (EApp (EVar "genInputsPlanned") (EVar "genEnv")) (EVar "evalEnv")) (EVar "rest")) (EVar "plans"))))
(DFunDef false "genInputsPlanned" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "property runner: prepared parameter plan mismatch"))))
(DTypeSig false "genParam" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Ty") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "genParam" ((PAs "ge" (PCon "GenEnv" (PVar "planEnv") PWild)) (PVar "evalEnv") (PVar "ty")) (EMatch (EApp (EApp (EApp (EApp (EVar "planFor") (EVar "planEnv")) (ELit (LString ""))) (ELit (LString "property parameter"))) (EVar "ty")) (arm (PCon "Ok" (PVar "plan")) () (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "evalEnv")) (ELit (LInt 0))) (EVar "plan"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EApp (EVar "planErrorText") (EVar "e"))))))
(DTypeSig false "genFromPlan" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GInt")) (EApp (EVar "VInt") (EApp (EApp (EVar "randIntRange") (EVar "intMin")) (EVar "intMax"))))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GBool")) (EApp (EVar "VBool") (EApp (EVar "randBoolL") (ELit LUnit))))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GFloat")) (EApp (EVar "genFloat") (ELit LUnit)))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GChar")) (EApp (EVar "VChar") (EApp (EVar "genCharStr") (ELit LUnit))))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GString")) (EApp (EVar "VString") (EApp (EVar "genString") (ELit LUnit))))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GUnit")) (EVar "VUnit"))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PCon "GList" (PVar "plan"))) (EApp (EVar "VList") (EApp (EApp (EApp (EApp (EApp (EVar "genPlanList") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "listLengthBound") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "depth")) (EVar "plan"))))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PCon "GArray" (PVar "plan"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EVar "genPlanList") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "listLengthBound") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "depth")) (EVar "plan")))))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PCon "GOption" (PVar "plan"))) (EApp (EApp (EApp (EApp (EApp (EVar "chooseOption") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan")) (EApp (EApp (EApp (EVar "optionWeights") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "depth")) (EVar "plan"))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PCon "GResult" (PVar "err") (PVar "ok"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chooseResult") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "err")) (EVar "ok")) (EApp (EApp (EApp (EApp (EVar "resultWeights") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "depth")) (EVar "err")) (EVar "ok"))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PCon "GTuple" (PVar "plans"))) (EApp (EVar "VTuple") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth"))) (EVar "plans"))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild))) (EMatch (EApp (EApp (EVar "planDef") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EApp (EVar "genPlannedCtor") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "nominal")) (EApp (EApp (EVar "choosePlanCtor") (EVar "ctors")) (EApp (EApp (EApp (EVar "ctorWeights") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "nominal")) (EVar "depth"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EApp (EVar "planErrorText") (EVar "e"))))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") PWild (PAs "custom" (PCon "GCustom" PWild))) (EApp (EApp (EApp (EVar "drawCustomArbitrary") (EVar "ge")) (EVar "env")) (EVar "custom")))
(DTypeSig false "genEnvPlan" (TyFun (TyCon "GenEnv") (TyCon "PlanEnv")))
(DFunDef false "genEnvPlan" ((PCon "GenEnv" (PVar "planEnv") PWild)) (EVar "planEnv"))
(DTypeSig false "drawCustomArbitrary" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "drawCustomArbitrary" ((PVar "ge") (PVar "env") (PVar "custom")) (EBlock (DoLet false false (PVar "programState") (EApp (EVar "readRandomState") (EVar "env"))) (DoLet false false PWild (EApp (EVar "ensureCustomRandomState") (EVar "env"))) (DoLet false false (PTuple (PVar "hi") (PVar "lo")) (EUnOp "!" (EVar "customRngStateRef"))) (DoLet false false PWild (EApp (EApp (EVar "restoreRandomStateValue") (EVar "env")) (EApp (EApp (EVar "VU64") (EVar "hi")) (EVar "lo")))) (DoLet false false (PVar "value") (EMatch (EApp (EApp (EVar "customHelper") (EVar "ge")) (EVar "custom")) (arm (PCon "Some" (PCon "PropHelper" PWild (PVar "genName") PWild)) () (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "genName")))) (EVar "VUnit")))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "property runner: missing selected typed custom helper")))))) (DoLet false false (PVar "customState") (EApp (EVar "readRandomState") (EVar "env"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customRngStateRef")) (EApp (EVar "u64Pair") (EVar "customState")))) (DoLet false false PWild (EApp (EApp (EVar "restoreRandomStateValue") (EVar "env")) (EVar "programState"))) (DoExpr (EVar "value"))))
(DTypeSig false "customHelper" (TyFun (TyCon "GenEnv") (TyFun (TyCon "GenPlan") (TyApp (TyCon "Option") (TyCon "PropHelper")))))
(DFunDef false "customHelper" ((PCon "GenEnv" PWild (PVar "helpers")) (PCon "GCustom" (PCon "CustomPlan" PWild PWild (PVar "word")))) (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "helpers")))
(DFunDef false "customHelper" (PWild PWild) (EVar "None"))
(DTypeSig false "helperFailure" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "helperFailure" ((PVar "ge") (PVar "env") (PVar "plans")) (EApp (EApp (EApp (EVar "helperFailureCustoms") (EVar "ge")) (EApp (EVar "envBindingNames") (EVar "env"))) (EApp (EApp (EVar "customPlansReachable") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "plans"))))
(DTypeSig false "helperFailureCustoms" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "helperFailureCustoms" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "helperFailureCustoms" ((PVar "ge") (PVar "names") (PCons (PVar "custom") (PVar "rest"))) (EMatch (EApp (EApp (EVar "customHelper") (EVar "ge")) (EApp (EVar "GCustom") (EVar "custom"))) (arm (PCon "Some" (PCon "PropHelper" PWild (PVar "genName") (PVar "shrinkName"))) () (EMatch (ETuple (EApp (EApp (EVar "omHasKey") (EVar "genName")) (EVar "names")) (EApp (EApp (EVar "omHasKey") (EVar "shrinkName")) (EVar "names"))) (arm (PTuple (PCon "True") (PCon "True")) () (EApp (EApp (EApp (EVar "helperFailureCustoms") (EVar "ge")) (EVar "names")) (EVar "rest"))) (arm PWild () (EApp (EVar "Some") (ELit (LString "selected typed custom helper binding is unavailable")))))) (arm (PCon "None") () (EApp (EVar "Some") (ELit (LString "selected typed custom helper is unavailable"))))))
(DTypeSig false "envBindingNames" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "envBindingNames" ((PCon "EvalEnv" (PVar "frames"))) (EApp (EApp (EVar "bindingNamesFrames") (EVar "frames")) (EVar "omEmpty")))
(DTypeSig false "bindingNamesFrames" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindingNamesFrames" ((PList) (PVar "names")) (EVar "names"))
(DFunDef false "bindingNamesFrames" ((PCons (PVar "frame") (PVar "rest")) (PVar "names")) (EApp (EApp (EVar "bindingNamesFrames") (EVar "rest")) (EApp (EApp (EVar "bindingNamesFrame") (EVar "frame")) (EVar "names"))))
(DTypeSig false "bindingNamesFrame" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindingNamesFrame" ((PList) (PVar "names")) (EVar "names"))
(DFunDef false "bindingNamesFrame" ((PCons (PTuple (PVar "name") PWild) (PVar "rest")) (PVar "names")) (EApp (EApp (EVar "bindingNamesFrame") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "names"))))
(DTypeSig false "ensureCustomRandomState" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "ensureCustomRandomState" ((PVar "env")) (EIf (EUnOp "!" (EVar "customRngReadyRef")) (ELit LUnit) (EBlock (DoLet false false (PVar "programState") (EApp (EVar "readRandomState") (EVar "env"))) (DoLet false false PWild (EApp (EApp (EVar "callRandomSetSeed") (EVar "env")) (EUnOp "!" (EVar "customSeedRef")))) (DoLet false false (PVar "seeded") (EApp (EVar "readRandomState") (EVar "env"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customRngStateRef")) (EApp (EVar "u64Pair") (EVar "seeded")))) (DoLet false false PWild (EApp (EApp (EVar "restoreRandomStateValue") (EVar "env")) (EVar "programState"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customRngReadyRef")) (EVar "True"))))))
(DTypeSig false "readRandomState" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "readRandomState" ((PVar "env")) (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupRuntimeBinding") (EVar "env")) (ELit (LString "randomState"))))) (EVar "VUnit"))))
(DTypeSig false "restoreRandomStateValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "restoreRandomStateValue" ((PVar "env") (PVar "state")) (EMatch (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupRuntimeBinding") (EVar "env")) (ELit (LString "restoreRandomState"))))) (EVar "state"))) (arm (PCon "VUnit") () (ELit LUnit)) (arm PWild () (EApp (EVar "panic") (ELit (LString "property runner: restoreRandomState returned a non-Unit value"))))))
(DTypeSig false "callRandomSetSeed" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "callRandomSetSeed" ((PVar "env") (PVar "seed")) (EMatch (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupRuntimeBinding") (EVar "env")) (ELit (LString "setSeed"))))) (EApp (EVar "VInt") (EVar "seed")))) (arm (PCon "VUnit") () (ELit LUnit)) (arm PWild () (EApp (EVar "panic") (ELit (LString "property runner: setSeed returned a non-Unit value"))))))
(DTypeSig false "u64Pair" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "u64Pair" ((PCon "VU64" (PVar "hi") (PVar "lo"))) (ETuple (EVar "hi") (EVar "lo")))
(DFunDef false "u64Pair" (PWild) (EApp (EVar "panic") (ELit (LString "property runner: randomState returned a non-U64 value"))))
(DTypeSig false "genPlanList" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "genPlanList" (PWild PWild PWild PWild (PLit (LInt 0))) (EListLit))
(DFunDef false "genPlanList" ((PVar "ge") (PVar "env") (PVar "depth") (PVar "plan") (PVar "n")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan")) (EApp (EApp (EApp (EApp (EApp (EVar "genPlanList") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "chooseOption" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "chooseOption" ((PVar "ge") (PVar "env") (PVar "depth") (PVar "plan") (PVar "weights")) (EIf (EApp (EVar "chooseWeight") (EVar "weights")) (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)) (EApp (EApp (EVar "VCon") (ELit (LString "Some"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan"))))))
(DTypeSig false "chooseResult" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "chooseResult" ((PVar "ge") (PVar "env") (PVar "depth") (PVar "err") (PVar "ok") (PVar "weights")) (EIf (EApp (EVar "chooseWeight") (EVar "weights")) (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "err")))) (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "ok"))))))
(DTypeSig false "chooseWeight" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "chooseWeight" ((PCons (PVar "first") (PCons (PVar "second") PWild))) (EBlock (DoLet false false (PVar "total") (EBinOp "+" (EVar "first") (EVar "second"))) (DoExpr (EIf (EBinOp "<=" (EVar "total") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "property runner: planner produced no finite branch"))) (EBinOp "<" (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EVar "total") (ELit (LInt 1)))) (EVar "first"))))))
(DFunDef false "chooseWeight" (PWild) (EApp (EVar "panic") (ELit (LString "property runner: planner returned malformed branch weights"))))
(DTypeSig false "choosePlanCtor" (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "PlanCtor"))))
(DFunDef false "choosePlanCtor" ((PList) PWild) (EApp (EVar "panic") (ELit (LString "property runner: nominal type has no constructors"))))
(DFunDef false "choosePlanCtor" ((PVar "ctors") (PVar "weights")) (EBlock (DoLet false false (PVar "total") (EApp (EVar "sumWeights") (EVar "weights"))) (DoExpr (EIf (EBinOp "<=" (EVar "total") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "property runner: planner produced no finite constructor"))) (EApp (EApp (EApp (EVar "choosePlanCtorAt") (EVar "ctors")) (EVar "weights")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EVar "total") (ELit (LInt 1)))))))))
(DTypeSig false "choosePlanCtorAt" (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "PlanCtor")))))
(DFunDef false "choosePlanCtorAt" ((PCons (PVar "ctor") PWild) (PList) PWild) (EVar "ctor"))
(DFunDef false "choosePlanCtorAt" ((PCons (PVar "ctor") PWild) (PCons (PVar "weight") PWild) (PVar "n")) (EIf (EBinOp "<" (EVar "n") (EVar "weight")) (EVar "ctor") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "choosePlanCtorAt" ((PCons PWild (PVar "ctors")) (PCons (PVar "weight") (PVar "weights")) (PVar "n")) (EApp (EApp (EApp (EVar "choosePlanCtorAt") (EVar "ctors")) (EVar "weights")) (EBinOp "-" (EVar "n") (EVar "weight"))))
(DFunDef false "choosePlanCtorAt" ((PList) PWild PWild) (EApp (EVar "panic") (ELit (LString "property runner: constructor weights were empty"))))
(DTypeSig false "sumWeights" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "sumWeights" ((PList)) (ELit (LInt 0)))
(DFunDef false "sumWeights" ((PCons (PVar "n") (PVar "rest"))) (EBinOp "+" (EVar "n") (EApp (EVar "sumWeights") (EVar "rest"))))
(DTypeSig false "nthList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "Int") (TyVar "a"))))
(DFunDef false "nthList" ((PCons (PVar "x") PWild) (PLit (LInt 0))) (EVar "x"))
(DFunDef false "nthList" ((PCons PWild (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "nthList") (EVar "rest")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))
(DFunDef false "nthList" ((PList) PWild) (EApp (EVar "panic") (ELit (LString "property runner: index out of range"))))
(DTypeSig false "genPlannedCtor" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genPlannedCtor" ((PVar "ge") (PVar "env") (PVar "depth") (PVar "nominal") (PAs "ctor" (PCon "PlanCtor" PWild (PVar "runtime") PWild))) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EVar "plannedCtorValue") (EVar "runtime")) (EApp (EApp (EApp (EApp (EVar "genPlannedFields") (EVar "ge")) (EVar "env")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "fields")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EApp (EVar "planErrorText") (EVar "e"))))))
(DTypeSig false "genPlannedFields" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "genPlannedFields" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "genPlannedFields" ((PVar "ge") (PVar "env") (PVar "depth") (PCons (PTuple (PVar "name") (PVar "plan")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan"))) (EApp (EApp (EApp (EApp (EVar "genPlannedFields") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "rest"))))
(DTypeSig false "plannedCtorValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "plannedCtorValue" ((PVar "runtime") (PList)) (EApp (EApp (EVar "VCon") (EVar "runtime")) (EListLit)))
(DFunDef false "plannedCtorValue" ((PVar "runtime") (PCons (PTuple (PCon "Some" (PVar "name")) (PVar "value")) (PVar "rest"))) (EApp (EApp (EVar "VRecord") (EVar "runtime")) (EBinOp "::" (ETuple (EVar "name") (EVar "value")) (EApp (EVar "namedPlanFields") (EVar "rest")))))
(DFunDef false "plannedCtorValue" ((PVar "runtime") (PCons (PTuple (PCon "None") (PVar "value")) (PVar "rest"))) (EApp (EApp (EVar "VCon") (EVar "runtime")) (EBinOp "::" (EVar "value") (EApp (EVar "positionalPlanFields") (EVar "rest")))))
(DTypeSig false "namedPlanFields" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "namedPlanFields" ((PList)) (EListLit))
(DFunDef false "namedPlanFields" ((PCons (PTuple (PCon "Some" (PVar "name")) (PVar "value")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "value")) (EApp (EVar "namedPlanFields") (EVar "rest"))))
(DFunDef false "namedPlanFields" ((PCons (PTuple (PCon "None") PWild) PWild)) (EApp (EVar "panic") (ELit (LString "property runner: mixed positional and named constructor fields"))))
(DTypeSig false "positionalPlanFields" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "positionalPlanFields" ((PList)) (EListLit))
(DFunDef false "positionalPlanFields" ((PCons (PTuple (PCon "None") (PVar "value")) (PVar "rest"))) (EBinOp "::" (EVar "value") (EApp (EVar "positionalPlanFields") (EVar "rest"))))
(DFunDef false "positionalPlanFields" ((PCons (PTuple (PCon "Some" PWild) PWild) PWild)) (EApp (EVar "panic") (ELit (LString "property runner: mixed positional and named constructor fields"))))
(DTypeSig false "shrinkForParam" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "shrinkForParam" ((PVar "ge") (PVar "env") (PVar "ty") (PVar "value")) (EMatch (EApp (EApp (EApp (EApp (EVar "planFor") (EApp (EVar "genEnvPlan") (EVar "ge"))) (ELit (LString ""))) (ELit (LString "property parameter"))) (EVar "ty")) (arm (PCon "Ok" (PAs "custom" (PCon "GCustom" PWild))) () (EMatch (EApp (EApp (EVar "customHelper") (EVar "ge")) (EVar "custom")) (arm (PCon "Some" (PCon "PropHelper" PWild PWild (PVar "shrinkName"))) () (EMatch (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "shrinkName")))) (EVar "value"))) (arm (PCon "VList" (PVar "smaller")) () (EVar "smaller")) (arm PWild () (EApp (EVar "panic") (ELit (LString "property runner: typed custom shrink returned a non-List value")))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "property runner: missing selected typed custom helper")))))) (arm (PCon "Ok" (PVar "plan")) () (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "value"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EApp (EVar "planErrorText") (EVar "e"))))))
(DTypeSig false "shrinkCustom" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "shrinkCustom" ((PVar "ge") (PVar "env") (PVar "custom") (PVar "value")) (EMatch (EApp (EApp (EVar "customHelper") (EVar "ge")) (EVar "custom")) (arm (PCon "Some" (PCon "PropHelper" PWild PWild (PVar "shrinkName"))) () (EMatch (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "shrinkName")))) (EVar "value"))) (arm (PCon "VList" (PVar "smaller")) () (EVar "smaller")) (arm PWild () (EApp (EVar "panic") (ELit (LString "property runner: typed custom shrink returned a non-List value")))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "property runner: missing selected typed custom helper"))))))
(DTypeSig false "structuralShrink" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GInt") (PCon "VInt" (PVar "n"))) (EApp (EVar "shrinkInt") (EVar "n")))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GBool") (PCon "VBool" (PCon "True"))) (EListLit (EApp (EVar "VBool") (EVar "False"))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GBool") PWild) (EListLit))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GFloat") (PCon "VFloat" (PVar "x"))) (EIf (EBinOp "==" (EVar "x") (ELit (LFloat 0.0))) (EListLit) (EListLit (EApp (EVar "VFloat") (ELit (LFloat 0.0))) (EApp (EVar "VFloat") (EBinOp "/" (EVar "x") (ELit (LFloat 2.0)))))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GString") (PCon "VString" (PVar "s"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EListLit) (EListLit (EApp (EVar "VString") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))) (EVar "s"))))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GChar") (PCon "VChar" PWild)) (EListLit))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GUnit") PWild) (EListLit))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GList" (PVar "plan")) (PCon "VList" (PVar "values"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "VList")) (EApp (EVar "deleteEach") (EVar "values"))) (EApp (EApp (EVar "map") (EVar "VList")) (EApp (EApp (EApp (EApp (EVar "shrinkElements") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "values")))))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GArray" (PVar "plan")) (PCon "VArray" (PVar "values"))) (EBlock (DoLet false false (PVar "xs") (EApp (EVar "toList") (EVar "values"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "xs2")) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EVar "xs2"))))) (EApp (EVar "deleteEach") (EVar "xs"))) (EApp (EApp (EVar "map") (ELam ((PVar "xs2")) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EVar "xs2"))))) (EApp (EApp (EApp (EApp (EVar "shrinkElements") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "xs")))))))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GOption" (PVar "plan")) (PCon "VCon" (PLit (LString "Some")) (PList (PVar "value")))) (EBinOp "::" (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EApp (EApp (EVar "VCon") (ELit (LString "Some"))) (EListLit (EVar "v"))))) (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "value")))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GOption" PWild) PWild) (EListLit))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GResult" (PVar "err") PWild) (PCon "VCon" (PLit (LString "Err")) (PList (PVar "value")))) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EVar "v"))))) (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "err")) (EVar "value"))))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GResult" PWild (PVar "ok")) (PCon "VCon" (PLit (LString "Ok")) (PList (PVar "value")))) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EVar "v"))))) (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "ok")) (EVar "value"))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GResult" PWild PWild) PWild) (EListLit))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GTuple" (PVar "plans")) (PCon "VTuple" (PVar "values"))) (EApp (EApp (EVar "map") (EVar "VTuple")) (EApp (EApp (EApp (EApp (EVar "shrinkPlanValues") (EVar "ge")) (EVar "env")) (EVar "plans")) (EVar "values"))))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild)) (PVar "value")) (EApp (EApp (EApp (EApp (EApp (EVar "shrinkNominal") (EVar "ge")) (EVar "env")) (EVar "nominal")) (EVar "key")) (EVar "value")))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PAs "custom" (PCon "GCustom" PWild)) (PVar "value")) (EApp (EApp (EApp (EApp (EVar "shrinkCustom") (EVar "ge")) (EVar "env")) (EVar "custom")) (EVar "value")))
(DFunDef false "structuralShrink" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "shrinkElements" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "shrinkElements" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "shrinkElements" ((PVar "ge") (PVar "env") (PVar "plan") (PCons (PVar "value") (PVar "values"))) (EBlock (DoLet false false (PVar "here") (EApp (EApp (EVar "map") (EApp (EVar "prependBefore") (EVar "values"))) (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "value")))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EVar "map") (EApp (EVar "prepend") (EVar "value"))) (EApp (EApp (EApp (EApp (EVar "shrinkElements") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "values")))))))
(DTypeSig false "shrinkPlanValues" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "shrinkPlanValues" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "shrinkPlanValues" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "shrinkPlanValues" ((PVar "ge") (PVar "env") (PCons (PVar "plan") (PVar "plans")) (PCons (PVar "value") (PVar "values"))) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "prependBefore") (EVar "values"))) (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "value"))) (EApp (EApp (EVar "map") (EApp (EVar "prepend") (EVar "value"))) (EApp (EApp (EApp (EApp (EVar "shrinkPlanValues") (EVar "ge")) (EVar "env")) (EVar "plans")) (EVar "values")))))
(DTypeSig false "shrinkNominal" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "shrinkNominal" ((PVar "ge") (PVar "env") (PVar "nominal") (PVar "key") (PVar "value")) (EMatch (EApp (EApp (EVar "planDef") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EBinOp "++" (EApp (EVar "nullaryCtorValues") (EVar "ctors")) (EApp (EApp (EApp (EApp (EApp (EVar "shrinkNominalFields") (EVar "ge")) (EVar "env")) (EVar "nominal")) (EVar "ctors")) (EVar "value")))) (arm (PCon "Err" PWild) () (EListLit))))
(DTypeSig false "nullaryCtorValues" (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "nullaryCtorValues" ((PList)) (EListLit))
(DFunDef false "nullaryCtorValues" ((PCons (PCon "PlanCtor" PWild (PVar "runtime") (PList)) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "VCon") (EVar "runtime")) (EListLit)) (EApp (EVar "nullaryCtorValues") (EVar "rest"))))
(DFunDef false "nullaryCtorValues" ((PCons PWild (PVar "rest"))) (EApp (EVar "nullaryCtorValues") (EVar "rest")))
(DTypeSig false "shrinkNominalFields" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "shrinkNominalFields" ((PVar "ge") (PVar "env") (PVar "nominal") (PVar "ctors") (PCon "VCon" (PVar "runtime") (PVar "values"))) (EMatch (EApp (EApp (EVar "planCtorRuntime") (EVar "runtime")) (EVar "ctors")) (arm (PCon "Some" (PVar "ctor")) () (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EVar "map") (ELam ((PVar "vs")) (EApp (EApp (EVar "VCon") (EVar "runtime")) (EVar "vs")))) (EApp (EApp (EApp (EApp (EVar "shrinkPlanValues") (EVar "ge")) (EVar "env")) (EApp (EVar "fieldPlans") (EVar "fields"))) (EVar "values")))) (arm (PCon "Err" PWild) () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DFunDef false "shrinkNominalFields" ((PVar "ge") (PVar "env") (PVar "nominal") (PVar "ctors") (PCon "VRecord" (PVar "runtime") (PVar "fields"))) (EMatch (EApp (EApp (EVar "planCtorRuntime") (EVar "runtime")) (EVar "ctors")) (arm (PCon "Some" (PVar "ctor")) () (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "plans")) () (EApp (EApp (EVar "map") (ELam ((PVar "vs")) (EApp (EApp (EVar "VRecord") (EVar "runtime")) (EApp (EApp (EVar "zipNames") (EApp (EVar "fieldNames") (EVar "fields"))) (EVar "vs"))))) (EApp (EApp (EApp (EApp (EVar "shrinkPlanValues") (EVar "ge")) (EVar "env")) (EApp (EVar "fieldPlans") (EVar "plans"))) (EApp (EVar "fieldValues") (EVar "fields"))))) (arm (PCon "Err" PWild) () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DFunDef false "shrinkNominalFields" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "planCtorRuntime" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyApp (TyCon "Option") (TyCon "PlanCtor")))))
(DFunDef false "planCtorRuntime" (PWild (PList)) (EVar "None"))
(DFunDef false "planCtorRuntime" ((PVar "runtime") (PCons (PAs "ctor" (PCon "PlanCtor" PWild (PVar "actual") PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EVar "runtime") (EVar "actual")) (EApp (EVar "Some") (EVar "ctor")) (EApp (EApp (EVar "planCtorRuntime") (EVar "runtime")) (EVar "rest"))))
(DTypeSig false "fieldPlans" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyApp (TyCon "List") (TyCon "GenPlan"))))
(DFunDef false "fieldPlans" ((PList)) (EListLit))
(DFunDef false "fieldPlans" ((PCons (PTuple PWild (PVar "plan")) (PVar "rest"))) (EBinOp "::" (EVar "plan") (EApp (EVar "fieldPlans") (EVar "rest"))))
(DTypeSig false "fieldNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldNames" ((PList)) (EListLit))
(DFunDef false "fieldNames" ((PCons (PTuple (PVar "name") PWild) (PVar "rest"))) (EBinOp "::" (EVar "name") (EApp (EVar "fieldNames") (EVar "rest"))))
(DTypeSig false "fieldValues" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "fieldValues" ((PList)) (EListLit))
(DFunDef false "fieldValues" ((PCons (PTuple PWild (PVar "value")) (PVar "rest"))) (EBinOp "::" (EVar "value") (EApp (EVar "fieldValues") (EVar "rest"))))
(DTypeSig false "zipNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "zipNames" ((PList) PWild) (EListLit))
(DFunDef false "zipNames" (PWild (PList)) (EListLit))
(DFunDef false "zipNames" ((PCons (PVar "name") (PVar "names")) (PCons (PVar "value") (PVar "values"))) (EBinOp "::" (ETuple (EVar "name") (EVar "value")) (EApp (EApp (EVar "zipNames") (EVar "names")) (EVar "values"))))
(DTypeSig false "printCounterexample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printCounterexample" ((PList)) (ELit LUnit))
(DFunDef false "printCounterexample" ((PCons (PTuple (PVar "x") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "ppValue") (EVar "v")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "printCounterexample") (EVar "rest")))))
(DTypeSig false "escStrLocal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStrLocal" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DTypeSig false "shrinkFuel" (TyCon "Int"))
(DFunDef false "shrinkFuel" () (ELit (LInt 10000)))
(DTypeSig false "shrinkLoop" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "Bool")))))))))
(DFunDef false "shrinkLoop" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoopFuel") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "shrinkFuel")))
(DTypeSig false "shrinkLoopFuel" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "Bool"))))))))))
(DFunDef false "shrinkLoopFuel" (PWild PWild PWild PWild (PVar "candidate") (PLit (LInt 0))) (ETuple (EVar "candidate") (EVar "True")))
(DFunDef false "shrinkLoopFuel" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "fuel")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (ELit (LInt 0))) (arm (PCon "Some" (PVar "better")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoopFuel") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "better")) (EBinOp "-" (EVar "fuel") (ELit (LInt 1))))) (arm (PCon "None") () (ETuple (EVar "candidate") (EVar "False")))))
(DTypeSig false "tryShrinkOne" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "tryShrinkOne" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "listLen") (EVar "params"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PCon "PropParam" (PVar "x") PWild (PVar "ty")) (EApp (EApp (EVar "nthList") (EVar "params")) (EVar "i"))) (DoLet false false (PVar "currentV") (EApp (EApp (EVar "assocVal") (EVar "x")) (EVar "candidate"))) (DoLet false false (PVar "smaller") (EApp (EApp (EApp (EApp (EVar "shrinkForParam") (EVar "genEnv")) (EVar "evalEnv")) (EVar "ty")) (EVar "currentV"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findSmaller") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "x")) (EVar "smaller")) (arm (PCon "Some" (PVar "better")) () (EApp (EVar "Some") (EVar "better"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findSmaller" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "findSmaller" (PWild PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "findSmaller" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "x") (PCons (PVar "sv") (PVar "rest"))) (EBlock (DoLet false false (PVar "candidate2") (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "candidate"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "candidate2")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findSmaller") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "x")) (EVar "rest")) (EApp (EVar "Some") (EVar "candidate2"))))))
(DTypeSig false "assocVal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "assocVal" ((PVar "x") (PVar "kvs")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "kvs")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "prop shrink: missing binding ")) (EVar "x"))))))
(DTypeSig false "replaceVal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "replaceVal" (PWild PWild (PList)) (EListLit))
(DFunDef false "replaceVal" ((PVar "x") (PVar "sv") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "x")) (EBinOp "::" (ETuple (EVar "k") (EVar "sv")) (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isProp" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isProp" ((PCon "DProp" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isProp" (PWild) (EVar "False"))
(DTypeSig true "filterProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "filterProps" ((PVar "decls")) (EApp (EApp (EVar "filterDecls") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "filterDecls" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterDecls" (PWild (PList)) (EListLit))
(DFunDef false "filterDecls" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "d")) (EBinOp "::" (EVar "d") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "filterPropsByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterPropsByName" ((PCon "None") (PVar "decls")) (EVar "decls"))
(DFunDef false "filterPropsByName" ((PCon "Some" (PVar "sub")) (PVar "decls")) (EApp (EApp (EVar "filterDecls") (EApp (EVar "propNameMatches") (EVar "sub"))) (EVar "decls")))
(DTypeSig false "propNameMatches" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "propNameMatches" ((PVar "sub") (PCon "DProp" PWild (PVar "name") PWild PWild)) (EApp (EApp (EVar "substringMatch") (EVar "sub")) (EVar "name")))
(DFunDef false "propNameMatches" (PWild PWild) (EVar "False"))
(DTypeSig true "runAllProps" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") (Some "e") (TyCon "Bool"))))))))))
(DFunDef false "runAllProps" ((PVar "cases") (PVar "filterOpt") (PVar "target") (PVar "propLines") (PVar "evalEnv") (PVar "program") (PVar "allDecls")) (EBlock (DoLet false false (PVar "props") (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "program")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "props")) (EVar "True") (EBlock (DoLet false false (PVar "genEnv") (EApp (EApp (EVar "buildGenEnv") (EVar "program")) (EVar "allDecls"))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEach") (EVar "cases")) (EVar "target")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "props"))) (DoLet false false (PVar "nPass") (EApp (EVar "countTrue") (EVar "results"))) (DoLet false false (PVar "nFail") (EBinOp "-" (EApp (EVar "listLen") (EVar "results")) (EVar "nPass"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nPass")))) (ELit (LString " passed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nFail")))) (ELit (LString " failed"))))) (DoExpr (EBinOp "==" (EVar "nFail") (ELit (LInt 0)))))))))
(DTypeSig false "runEach" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") (Some "e") (TyApp (TyCon "List") (TyCon "Bool"))))))))))
(DFunDef false "runEach" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "runEach" ((PVar "cases") (PVar "target") (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProp") (EVar "genEnv")) (EVar "evalEnv")) (EVar "p")) (EVar "cases")) (EVar "target")) (EVar "propLines")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEach") (EVar "cases")) (EVar "target")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rest"))))
(DTypeSig false "countTrue" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyCon "Int")))
(DFunDef false "countTrue" ((PList)) (ELit (LInt 0)))
(DFunDef false "countTrue" ((PCons (PCon "True") (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countTrue") (EVar "rest"))))
(DFunDef false "countTrue" ((PCons (PCon "False") (PVar "rest"))) (EApp (EVar "countTrue") (EVar "rest")))
(DData Public "PropStatus" () ((variant "PropPassedResult" (ConPos)) (variant "PropFailedResult" (ConPos)) (variant "PropErroredResult" (ConPos))) ())
(DData Public "PropFailureKind" () ((variant "PropLawFalse" (ConPos)) (variant "PropCapabilityError" (ConPos)) (variant "PropBuildError" (ConPos)) (variant "PropRuntimeError" (ConPos)) (variant "PropProtocolError" (ConPos)) (variant "PropTypeError" (ConPos))) ())
(DData Public "PropRequest" () ((variant "PropRequest" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "propRequestName" (TyFun (TyCon "PropRequest") (TyCon "String")))
(DFunDef false "propRequestName" ((PCon "PropRequest" (PVar "name") PWild PWild)) (EVar "name"))
(DTypeSig true "propRequestSeed" (TyFun (TyCon "PropRequest") (TyCon "Int")))
(DFunDef false "propRequestSeed" ((PCon "PropRequest" PWild (PVar "seed") PWild)) (EVar "seed"))
(DTypeSig true "propRequestCases" (TyFun (TyCon "PropRequest") (TyCon "Int")))
(DFunDef false "propRequestCases" ((PCon "PropRequest" PWild PWild (PVar "cases"))) (EVar "cases"))
(DData Public "PropResult" () ((variant "PropResult" (ConPos (TyCon "String") (TyCon "String") (TyCon "PropStatus") (TyApp (TyCon "Option") (TyCon "PropFailureKind")) (TyCon "String") (TyCon "Int") (TyCon "Int")))) ())
(DData Public "PreparedPropRequest" () ((variant "PreparedRun" (ConPos (TyCon "PropRequest") (TyCon "Decl") (TyApp (TyCon "List") (TyCon "GenPlan")))) (variant "PreparedResult" (ConPos (TyCon "PropResult")))) ())
(DTypeSig true "propResultName" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "propResultName" ((PCon "PropResult" PWild (PVar "n") PWild PWild PWild PWild PWild)) (EVar "n"))
(DTypeSig true "propResultEngine" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "propResultEngine" ((PCon "PropResult" (PVar "e") PWild PWild PWild PWild PWild PWild)) (EVar "e"))
(DTypeSig true "propResultPassed" (TyFun (TyCon "PropResult") (TyCon "Bool")))
(DFunDef false "propResultPassed" ((PCon "PropResult" PWild PWild (PCon "PropPassedResult") PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "propResultPassed" (PWild) (EVar "False"))
(DTypeSig true "propResultDetail" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "propResultDetail" ((PCon "PropResult" PWild PWild PWild PWild (PVar "d") PWild PWild)) (EVar "d"))
(DTypeSig true "propResultStatus" (TyFun (TyCon "PropResult") (TyCon "PropStatus")))
(DFunDef false "propResultStatus" ((PCon "PropResult" PWild PWild (PVar "s") PWild PWild PWild PWild)) (EVar "s"))
(DTypeSig true "propResultFailureKind" (TyFun (TyCon "PropResult") (TyApp (TyCon "Option") (TyCon "PropFailureKind"))))
(DFunDef false "propResultFailureKind" ((PCon "PropResult" PWild PWild PWild (PVar "kind") PWild PWild PWild)) (EVar "kind"))
(DTypeSig true "propResultSeed" (TyFun (TyCon "PropResult") (TyCon "Int")))
(DFunDef false "propResultSeed" ((PCon "PropResult" PWild PWild PWild PWild PWild (PVar "seed") PWild)) (EVar "seed"))
(DTypeSig true "propResultCases" (TyFun (TyCon "PropResult") (TyCon "Int")))
(DFunDef false "propResultCases" ((PCon "PropResult" PWild PWild PWild PWild PWild PWild (PVar "cases"))) (EVar "cases"))
(DTypeSig true "runAllPropsResults" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runAllPropsResults" ((PVar "cases") (PVar "filterOpt") (PVar "propLines") (PVar "evalEnv") (PVar "program") (PVar "allDecls")) (EBlock (DoLet false false (PVar "props") (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "program")))) (DoLet false false (PVar "rootEnv") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EVar "evalEnv"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "props")) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EApp (EApp (EVar "buildGenEnv") (EVar "program")) (EVar "allDecls"))) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "props"))))))
(DTypeSig true "runAllPropRequestsResults" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runAllPropRequestsResults" ((PVar "requests") (PVar "propLines") (PVar "evalEnv") (PVar "program") (PVar "allDecls")) (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequests") (EVar "requests")) (EVar "propLines")) (EApp (EApp (EVar "buildGenEnv") (EVar "program")) (EVar "allDecls"))) (EVar "evalEnv")) (EApp (EVar "filterProps") (EVar "program"))))
(DTypeSig true "runAllPlannedPropRequestsResults" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runAllPlannedPropRequestsResults" ((PVar "root") (PVar "modules") (PVar "requests") (PVar "propLines") (PVar "evalEnv") (PVar "program")) (EMatch (EApp (EApp (EVar "buildPlanEnvModules") (EVar "root")) (EVar "modules")) (arm (PCon "Ok" (PVar "planEnv")) () (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequestsInEnv") (EVar "requests")) (EVar "propLines")) (EApp (EApp (EVar "buildGenEnvWithPlan") (EApp (EVar "runtimeModuleDecls") (EVar "modules"))) (EVar "planEnv"))) (EVar "evalEnv")) (EApp (EVar "filterProps") (EVar "program")))) (arm (PCon "Err" (PVar "err")) () (EApp (EApp (EVar "map") (EApp (EVar "requestPlanError") (EVar "err"))) (EVar "requests")))))
(DTypeSig true "preparePlannedPropRequests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyTuple (TyCon "PlanEnv") (TyApp (TyCon "List") (TyCon "PreparedPropRequest")))))))))
(DFunDef false "preparePlannedPropRequests" ((PVar "root") (PVar "modules") (PVar "requests") (PVar "rootProps")) (EApp (EApp (EVar "map") (ELam ((PVar "env")) (ETuple (EVar "env") (EApp (EApp (EApp (EApp (EVar "prepareRequests") (EVar "env")) (EVar "requests")) (EVar "requests")) (EApp (EVar "filterProps") (EVar "rootProps")))))) (EApp (EApp (EVar "buildPlanEnvModules") (EVar "root")) (EVar "modules"))))
(DTypeSig false "prepareRequests" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "PreparedPropRequest")))))))
(DFunDef false "prepareRequests" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "prepareRequests" ((PVar "env") (PVar "all") (PCons (PAs "request" (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (PVar "rest")) (PVar "props")) (EBlock (DoLet false false (PVar "row") (EIf (EApp (EApp (EVar "requestNameRepeated") (EVar "name")) (EVar "all")) (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EVar "duplicateRequest") (EVar "name")) (EVar "seed")) (EVar "cases"))) (EIf (EBinOp "<=" (EVar "cases") (ELit (LInt 0))) (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "property request has a non-positive case count"))) (EVar "seed")) (EVar "cases"))) (EMatch (EApp (EApp (EVar "propsNamed") (EVar "name")) (EVar "props")) (arm (PList (PAs "decl" (PCon "DProp" PWild PWild (PVar "params") PWild))) () (EMatch (EApp (EApp (EApp (EVar "planPropParams") (EVar "env")) (EVar "name")) (EVar "params")) (arm (PCon "Ok" (PVar "plans")) () (EApp (EApp (EApp (EVar "PreparedRun") (EVar "request")) (EVar "decl")) (EVar "plans"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EApp (EVar "capabilityResult") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "e")))))) (arm (PList) () (EApp (EVar "PreparedResult") (EApp (EVar "missingRequest") (EVar "request")))) (arm PWild () (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "property request is ambiguous: the root module declares '{name}' more than once"))) (EVar "seed")) (EVar "cases")))))))) (DoExpr (EBinOp "::" (EVar "row") (EApp (EApp (EApp (EApp (EVar "prepareRequests") (EVar "env")) (EVar "all")) (EVar "rest")) (EVar "props"))))))
(DTypeSig true "runPreparedPropRequestsResults" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runPreparedPropRequestsResults" ((PVar "planEnv") (PVar "helpers") (PVar "rows") (PVar "propLines") (PVar "evalEnv") (PVar "runtimeDecls")) (EApp (EApp (EApp (EApp (EVar "runPreparedRows") (EApp (EApp (EApp (EVar "buildGenEnvWithHelpers") (EVar "runtimeDecls")) (EVar "planEnv")) (EVar "helpers"))) (EVar "rows")) (EVar "propLines")) (EVar "evalEnv")))
(DTypeSig false "runPreparedRows" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult"))))))))
(DFunDef false "runPreparedRows" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "runPreparedRows" ((PVar "genEnv") (PCons (PCon "PreparedResult" (PVar "result")) (PVar "rest")) (PVar "propLines") (PVar "evalEnv")) (EBinOp "::" (EVar "result") (EApp (EApp (EApp (EApp (EVar "runPreparedRows") (EVar "genEnv")) (EVar "rest")) (EVar "propLines")) (EVar "evalEnv"))))
(DFunDef false "runPreparedRows" ((PVar "genEnv") (PCons (PCon "PreparedRun" (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases")) (PCon "DProp" PWild PWild (PVar "params") (PVar "body")) (PVar "plans")) (PVar "rest")) (PVar "propLines") (PVar "evalEnv")) (EBlock (DoLet false false PWild (EApp (EVar "seedPropRng") (EVar "seed"))) (DoExpr (EBinOp "::" (EMatch (EApp (EApp (EApp (EVar "helperFailure") (EVar "genEnv")) (EVar "evalEnv")) (EVar "plans")) (arm (PCon "Some" (PVar "detail")) () (EApp (EApp (EApp (EApp (EVar "runtimeResult") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "detail"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "beginCustomPropStream") (EVar "seed"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propResultOf") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "plans")) (EVar "cases")) (EVar "seed")) (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailurePlanned") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "plans")) (EVar "body")) (EVar "cases")) (ELit (LInt 1)))))))) (EApp (EApp (EApp (EApp (EVar "runPreparedRows") (EVar "genEnv")) (EVar "rest")) (EVar "propLines")) (EVar "evalEnv"))))))
(DFunDef false "runPreparedRows" ((PVar "genEnv") (PCons PWild (PVar "rest")) (PVar "propLines") (PVar "evalEnv")) (EApp (EApp (EApp (EApp (EVar "runPreparedRows") (EVar "genEnv")) (EVar "rest")) (EVar "propLines")) (EVar "evalEnv")))
(DTypeSig true "runAllPlannedPropRequestsWithHelpersResults" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult")))))))))))
(DFunDef false "runAllPlannedPropRequestsWithHelpersResults" ((PVar "root") (PVar "modules") (PVar "helpers") (PVar "requests") (PVar "propLines") (PVar "evalEnv") (PVar "program")) (EMatch (EApp (EApp (EVar "buildPlanEnvModules") (EVar "root")) (EVar "modules")) (arm (PCon "Ok" (PVar "planEnv")) () (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequestsInEnv") (EVar "requests")) (EVar "propLines")) (EApp (EApp (EApp (EVar "buildGenEnvWithHelpers") (EApp (EVar "runtimeModuleDecls") (EVar "modules"))) (EVar "planEnv")) (EVar "helpers"))) (EVar "evalEnv")) (EApp (EVar "filterProps") (EVar "program")))) (arm (PCon "Err" (PVar "err")) () (EApp (EApp (EVar "map") (EApp (EVar "requestPlanError") (EVar "err"))) (EVar "requests")))))
(DTypeSig false "runtimeModuleDecls" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "runtimeModuleDecls" ((PList)) (EListLit))
(DFunDef false "runtimeModuleDecls" ((PCons (PCon "PlanModule" PWild PWild (PVar "runtime")) (PVar "rest"))) (EBinOp "++" (EVar "runtime") (EApp (EVar "runtimeModuleDecls") (EVar "rest"))))
(DTypeSig false "requestPlanError" (TyFun (TyCon "PlanError") (TyFun (TyCon "PropRequest") (TyCon "PropResult"))))
(DFunDef false "requestPlanError" ((PVar "err") (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (EApp (EApp (EApp (EApp (EVar "capabilityResult") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "err")))
(DTypeSig false "runPropRequests" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runPropRequests" ((PVar "requests") (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PVar "props")) (EBlock (DoLet false false (PVar "rootEnv") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EVar "evalEnv"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequestsChecked") (EVar "requests")) (EVar "requests")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "props")))))
(DTypeSig false "runPropRequestsInEnv" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runPropRequestsInEnv" ((PVar "requests") (PVar "propLines") (PVar "genEnv") (PVar "rootEnv") (PVar "props")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequestsChecked") (EVar "requests")) (EVar "requests")) (EVar "propLines")) (EVar "genEnv")) (EListLit)) (EVar "rootEnv")) (EVar "props")))
(DTypeSig false "runPropRequestsChecked" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult")))))))))))
(DFunDef false "runPropRequestsChecked" (PWild (PList) PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "runPropRequestsChecked" ((PVar "all") (PCons (PAs "request" (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (PVar "rest")) (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PVar "rootEnv") (PVar "props")) (EBlock (DoLet false false (PVar "result") (EIf (EApp (EApp (EVar "requestNameRepeated") (EVar "name")) (EVar "all")) (EApp (EApp (EApp (EVar "duplicateRequest") (EVar "name")) (EVar "seed")) (EVar "cases")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequest") (EVar "request")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "props")))) (DoExpr (EBinOp "::" (EVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequestsChecked") (EVar "all")) (EVar "rest")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "props"))))))
(DTypeSig false "requestNameRepeated" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyCon "Bool"))))
(DFunDef false "requestNameRepeated" ((PVar "name") (PVar "requests")) (EBinOp ">" (EApp (EApp (EVar "requestNameCount") (EVar "name")) (EVar "requests")) (ELit (LInt 1))))
(DTypeSig false "requestNameCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyCon "Int"))))
(DFunDef false "requestNameCount" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "requestNameCount" ((PVar "name") (PCons (PCon "PropRequest" (PVar "actual") PWild PWild) (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "==" (EVar "name") (EVar "actual")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EApp (EVar "requestNameCount") (EVar "name")) (EVar "rest"))))
(DTypeSig false "duplicateRequest" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "PropResult")))))
(DFunDef false "duplicateRequest" ((PVar "name") (PVar "seed") (PVar "cases")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "property request names '{name}' more than once"))) (EVar "seed")) (EVar "cases")))
(DTypeSig false "runPropRequest" (TyFun (TyCon "PropRequest") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyCon "PropResult")))))))))
(DFunDef false "runPropRequest" ((PAs "request" (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PVar "rootEnv") (PVar "props")) (EBlock (DoLet false false (PVar "matches") (EApp (EApp (EVar "propsNamed") (EVar "name")) (EVar "props"))) (DoExpr (EIf (EBinOp "<=" (EVar "cases") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "property request has a non-positive case count"))) (EVar "seed")) (EVar "cases")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "matches")) (ELit (LInt 1))) (EBlock (DoLet false false PWild (EApp (EVar "seedPropRng") (EVar "seed"))) (DoExpr (EMatch (EVar "matches") (arm (PList (PCon "DProp" PWild PWild (PVar "params") (PVar "body"))) () (EMatch (EApp (EApp (EApp (EVar "planPropParams") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "name")) (EVar "params")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "capabilityResult") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "e"))) (arm (PCon "Ok" (PVar "plans")) () (EMatch (EApp (EApp (EApp (EVar "helperFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "plans")) (arm (PCon "Some" (PVar "detail")) () (EApp (EApp (EApp (EApp (EVar "runtimeResult") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "detail"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "beginCustomPropStream") (EVar "seed"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propResultOf") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "plans")) (EVar "cases")) (EVar "seed")) (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "params")) (EVar "body")) (EVar "cases")) (ELit (LInt 1))))))))))) (arm PWild () (EApp (EVar "missingRequest") (EVar "request")))))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "matches")) (ELit (LInt 0))) (EApp (EVar "missingRequest") (EVar "request")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EBinOp "++" (EBinOp "++" (ELit (LString "property request is ambiguous: the root module declares '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' more than once")))) (EVar "seed")) (EVar "cases"))))))))
(DTypeSig false "propsNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "propsNamed" (PWild (PList)) (EListLit))
(DFunDef false "propsNamed" ((PVar "wanted") (PCons (PAs "d" (PCon "DProp" PWild (PVar "name") PWild PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EVar "wanted") (EVar "name")) (EBinOp "::" (EVar "d") (EApp (EApp (EVar "propsNamed") (EVar "wanted")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "propsNamed") (EVar "wanted")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "propsNamed" ((PVar "wanted") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "propsNamed") (EVar "wanted")) (EVar "rest")))
(DTypeSig false "missingRequest" (TyFun (TyCon "PropRequest") (TyCon "PropResult")))
(DFunDef false "missingRequest" ((PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EBinOp "++" (EBinOp "++" (ELit (LString "property request names no root declaration '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "'")))) (EVar "seed")) (EVar "cases")))
(DTypeSig false "runEachResult" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runEachResult" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "runEachResult" ((PVar "cases") (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PVar "rootEnv") (PCons (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "seedAtStart") (EUnOp "!" (EVar "propRngStateRef"))) (DoExpr (EBinOp "::" (EMatch (EApp (EApp (EApp (EVar "planPropParams") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "name")) (EVar "params")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "capabilityResult") (EVar "name")) (EVar "seedAtStart")) (EVar "cases")) (EVar "e"))) (arm (PCon "Ok" (PVar "plans")) () (EMatch (EApp (EApp (EApp (EVar "helperFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "plans")) (arm (PCon "Some" (PVar "detail")) () (EApp (EApp (EApp (EApp (EVar "runtimeResult") (EVar "name")) (EVar "seedAtStart")) (EVar "cases")) (EVar "detail"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "beginCustomPropStream") (EVar "seedAtStart"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propResultOf") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "plans")) (EVar "cases")) (EVar "seedAtStart")) (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "params")) (EVar "body")) (EVar "cases")) (ELit (LInt 1)))))))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "rest"))))))
(DFunDef false "runEachResult" ((PVar "cases") (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PVar "rootEnv") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "rest")))
(DTypeSig false "planPropParams" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "GenPlan")))))))
(DFunDef false "planPropParams" (PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "planPropParams" ((PVar "planEnv") (PVar "propName") (PCons (PCon "PropParam" (PVar "param") PWild (PVar "ty")) (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planFor") (EVar "planEnv")) (EVar "propName")) (EVar "param")) (EVar "ty")) (EApp (EApp (EApp (EVar "planPropParams") (EVar "planEnv")) (EVar "propName")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "plan")) (PCon "Ok" (PVar "plans"))) () (EApp (EVar "Ok") (EBinOp "::" (EVar "plan") (EVar "plans")))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "capabilityResult" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "PlanError") (TyCon "PropResult"))))))
(DFunDef false "capabilityResult" ((PVar "name") (PVar "seed") (PVar "cases") (PVar "err")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropCapabilityError"))) (EApp (EVar "planErrorText") (EVar "err"))) (EVar "seed")) (EVar "cases")))
(DTypeSig false "runtimeResult" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "PropResult"))))))
(DFunDef false "runtimeResult" ((PVar "name") (PVar "seed") (PVar "cases") (PVar "detail")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropRuntimeError"))) (EVar "detail")) (EVar "seed")) (EVar "cases")))
(DTypeSig false "propResultOf" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "PropResult")))))))))
(DFunDef false "propResultOf" (PWild PWild (PVar "cases") (PVar "seed") (PVar "_line") (PVar "name") (PCon "PropPassed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropPassedResult")) (EVar "None")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "cases")))) (ELit (LString " tests passed")))) (EVar "seed")) (EVar "cases")))
(DFunDef false "propResultOf" ((PVar "planEnv") (PVar "plans") (PVar "cases") (PVar "seed") (PVar "line") (PVar "name") (PCon "PropFailed" (PVar "run") (PVar "shrunk") (PVar "fuelExhausted"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropFailedResult")) (EApp (EVar "Some") (EVar "PropLawFalse"))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "lineDetailPrefix") (EVar "line")) (ELit (LString "failed after ")) (EApp (EVar "intToString") (EVar "run")) (EIf (EBinOp "==" (EVar "run") (ELit (LInt 1))) (ELit (LString " test; counterexample: ")) (ELit (LString " tests; counterexample: "))) (EApp (EApp (EApp (EVar "renderCounterexample") (EVar "planEnv")) (EVar "plans")) (EVar "shrunk")) (EIf (EVar "fuelExhausted") (ELit (LString " (WARNING: shrink fuel exhausted, counterexample may not be minimal — see #1307)")) (ELit (LString "")))))) (EVar "seed")) (EVar "cases")))
(DTypeSig false "lineDetailPrefix" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "lineDetailPrefix" ((PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "lineDetailPrefix" ((PVar "line")) (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))))
(DTypeSig false "renderCounterexample" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "String")))))
(DFunDef false "renderCounterexample" (PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "renderCounterexample" ((PVar "env") (PCons (PVar "plan") (PVar "plans")) (PList (PTuple (PVar "name") (PVar "value")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value")))) (ELit (LString ""))))
(DFunDef false "renderCounterexample" ((PVar "env") (PCons (PVar "plan") (PVar "plans")) (PCons (PTuple (PVar "name") (PVar "value")) (PVar "rest"))) (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString " = ")) (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value")) (ELit (LString ", ")) (EApp (EApp (EApp (EVar "renderCounterexample") (EVar "env")) (EVar "plans")) (EVar "rest")))))
(DFunDef false "renderCounterexample" (PWild PWild (PList (PTuple (PVar "name") PWild))) (EBinOp "++" (EVar "name") (ELit (LString " = <unplanned>"))))
(DFunDef false "renderCounterexample" ((PVar "env") (PList) (PCons (PTuple (PVar "name") PWild) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " = <unplanned>, "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "renderCounterexample") (EVar "env")) (EListLit)) (EVar "rest")))) (ELit (LString ""))))
(DTypeSig false "renderPlanValue" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String")))))
(DFunDef false "renderPlanValue" (PWild (PCon "GInt") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" (PWild (PCon "GBool") (PCon "VBool" (PCon "True"))) (ELit (LString "True")))
(DFunDef false "renderPlanValue" (PWild (PCon "GBool") (PCon "VBool" (PCon "False"))) (ELit (LString "False")))
(DFunDef false "renderPlanValue" (PWild (PCon "GBool") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" (PWild (PCon "GFloat") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" (PWild (PCon "GChar") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" (PWild (PCon "GString") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" (PWild (PCon "GUnit") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GList" (PVar "plan")) (PCon "VList" (PVar "values"))) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EApp (EApp (EVar "renderPlanValues") (EVar "env")) (EVar "plan")) (EVar "values"))) (ELit (LString "]"))))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GArray" (PVar "plan")) (PCon "VArray" (PVar "values"))) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EApp (EApp (EVar "renderPlanValues") (EVar "env")) (EVar "plan")) (EApp (EVar "arrayValues") (EVar "values")))) (ELit (LString "]"))))
(DFunDef false "renderPlanValue" (PWild (PCon "GOption" PWild) (PCon "VCon" (PLit (LString "None")) (PList))) (ELit (LString "None")))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GOption" (PVar "plan")) (PCon "VCon" (PLit (LString "Some")) (PList (PVar "value")))) (EBinOp "++" (EBinOp "++" (ELit (LString "Some(")) (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value"))) (ELit (LString ")"))))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GResult" (PVar "err") PWild) (PCon "VCon" (PLit (LString "Err")) (PList (PVar "value")))) (EBinOp "++" (EBinOp "++" (ELit (LString "Err(")) (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "err")) (EVar "value"))) (ELit (LString ")"))))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GResult" PWild (PVar "ok")) (PCon "VCon" (PLit (LString "Ok")) (PList (PVar "value")))) (EBinOp "++" (EBinOp "++" (ELit (LString "Ok(")) (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "ok")) (EVar "value"))) (ELit (LString ")"))))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GTuple" (PVar "plans")) (PCon "VTuple" (PVar "values"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EApp (EVar "renderPlanValuePairs") (EVar "env")) (EVar "plans")) (EVar "values"))) (ELit (LString ")"))))
(DFunDef false "renderPlanValue" ((PVar "env") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild)) (PVar "value")) (EApp (EApp (EApp (EApp (EVar "renderNominalValue") (EVar "env")) (EVar "nominal")) (EVar "key")) (EVar "value")))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GCustom" (PCon "CustomPlan" (PVar "key") (PVar "carrier") PWild)) (PVar "value")) (EMatch (EApp (EApp (EVar "displayCarrierPlans") (EVar "env")) (EApp (EVar "carrierArgs") (EVar "carrier"))) (arm (PCon "Some" (PVar "args")) () (EApp (EApp (EApp (EApp (EVar "renderNominalValue") (EVar "env")) (EApp (EApp (EVar "GNominal") (EVar "key")) (EVar "args"))) (EVar "key")) (EVar "value"))) (arm (PCon "None") () (EApp (EVar "hiddenType") (EVar "key")))))
(DFunDef false "renderPlanValue" (PWild PWild PWild) (ELit (LString "<value>")))
(DTypeSig false "renderPlanValues" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "String")))))
(DFunDef false "renderPlanValues" (PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "renderPlanValues" ((PVar "env") (PVar "plan") (PList (PVar "value"))) (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value")))
(DFunDef false "renderPlanValues" ((PVar "env") (PVar "plan") (PCons (PVar "value") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "renderPlanValues") (EVar "env")) (EVar "plan")) (EVar "rest")))) (ELit (LString ""))))
(DTypeSig false "arrayValues" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "arrayValues" ((PVar "values")) (EApp (EApp (EApp (EVar "arrayValuesGo") (EVar "values")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "values"))))
(DTypeSig false "arrayValuesGo" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "arrayValuesGo" (PWild (PVar "index") (PVar "size")) (EIf (EBinOp ">=" (EVar "index") (EVar "size")) (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "arrayValuesGo" ((PVar "values") (PVar "index") (PVar "size")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "index")) (EVar "values")) (EApp (EApp (EApp (EVar "arrayValuesGo") (EVar "values")) (EBinOp "+" (EVar "index") (ELit (LInt 1)))) (EVar "size"))))
(DTypeSig false "renderPlanValuePairs" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "String")))))
(DFunDef false "renderPlanValuePairs" (PWild (PList) (PList)) (ELit (LString "")))
(DFunDef false "renderPlanValuePairs" ((PVar "env") (PCons (PVar "plan") (PVar "plans")) (PCons (PVar "value") (PVar "values"))) (EBlock (DoLet false false (PVar "rendered") (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "plans")) (EApp (EVar "isEmptyL") (EVar "values"))) (EVar "rendered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "rendered"))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "renderPlanValuePairs") (EVar "env")) (EVar "plans")) (EVar "values")))) (ELit (LString "")))))))
(DFunDef false "renderPlanValuePairs" (PWild PWild PWild) (ELit (LString "<value>")))
(DTypeSig false "renderNominalValue" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String"))))))
(DFunDef false "renderNominalValue" ((PVar "env") (PVar "nominal") (PVar "key") (PVar "value")) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EApp (EApp (EApp (EApp (EApp (EVar "renderVisibleNominal") (EVar "env")) (EVar "nominal")) (EVar "key")) (EVar "ctors")) (EVar "value")) (EApp (EVar "hiddenType") (EVar "key")))) (arm (PCon "Err" PWild) () (EApp (EVar "hiddenType") (EVar "key")))))
(DTypeSig false "nominalVisible" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "PlanVisibility") (TyCon "Bool")))))
(DFunDef false "nominalVisible" (PWild PWild (PCon "PlanPublicCtors")) (EVar "True"))
(DFunDef false "nominalVisible" ((PCon "PlanEnv" (PVar "root") PWild PWild PWild PWild) (PVar "owner") (PCon "PlanLocal")) (EBinOp "==" (EVar "owner") (EVar "root")))
(DFunDef false "nominalVisible" ((PCon "PlanEnv" (PVar "root") PWild PWild PWild PWild) (PVar "owner") (PCon "PlanAbstract")) (EBinOp "==" (EVar "owner") (EVar "root")))
(DTypeSig false "hiddenType" (TyFun (TyCon "TypeKey") (TyCon "String")))
(DFunDef false "hiddenType" ((PCon "TypeKey" (PVar "name") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EVar "name")) (ELit (LString ">"))))
(DTypeSig false "renderVisibleNominal" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String")))))))
(DFunDef false "renderVisibleNominal" ((PVar "env") (PVar "nominal") (PVar "key") (PVar "ctors") (PCon "VCon" (PVar "runtime") (PVar "values"))) (EMatch (EApp (EApp (EVar "runtimeCtor") (EVar "runtime")) (EVar "ctors")) (arm (PCon "Some" (PVar "ctor")) () (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "renderPositionalCtor") (EVar "env")) (EVar "ctor")) (EVar "fields")) (EVar "values"))) (arm (PCon "Err" PWild) () (EApp (EVar "hiddenType") (EVar "key"))))) (arm (PCon "None") () (EApp (EVar "hiddenType") (EVar "key")))))
(DFunDef false "renderVisibleNominal" ((PVar "env") (PVar "nominal") (PVar "key") (PVar "ctors") (PCon "VRecord" (PVar "runtime") (PVar "values"))) (EMatch (EApp (EApp (EVar "runtimeCtor") (EVar "runtime")) (EVar "ctors")) (arm (PCon "Some" (PVar "ctor")) () (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "renderNamedCtor") (EVar "env")) (EVar "ctor")) (EVar "fields")) (EVar "values"))) (arm (PCon "Err" PWild) () (EApp (EVar "hiddenType") (EVar "key"))))) (arm (PCon "None") () (EApp (EVar "hiddenType") (EVar "key")))))
(DFunDef false "renderVisibleNominal" (PWild PWild (PVar "key") PWild PWild) (EApp (EVar "hiddenType") (EVar "key")))
(DTypeSig false "runtimeCtor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyApp (TyCon "Option") (TyCon "PlanCtor")))))
(DFunDef false "runtimeCtor" (PWild (PList)) (EVar "None"))
(DFunDef false "runtimeCtor" ((PVar "runtime") (PCons (PAs "ctor" (PCon "PlanCtor" PWild (PVar "actual") PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EVar "runtime") (EVar "actual")) (EApp (EVar "Some") (EVar "ctor")) (EIf (EVar "otherwise") (EApp (EApp (EVar "runtimeCtor") (EVar "runtime")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "renderPositionalCtor" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "PlanCtor") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "String"))))))
(DFunDef false "renderPositionalCtor" ((PVar "env") (PCon "PlanCtor" (PVar "source") PWild PWild) (PVar "fields") (PVar "values")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "source"))) (ELit (LString "("))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "renderFields") (EVar "env")) (EVar "fields")) (EVar "values")))) (ELit (LString ")"))))
(DTypeSig false "renderNamedCtor" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "PlanCtor") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "String"))))))
(DFunDef false "renderNamedCtor" ((PVar "env") (PCon "PlanCtor" (PVar "source") PWild PWild) (PVar "fields") (PVar "values")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "source"))) (ELit (LString " { "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "renderNamedFields") (EVar "env")) (EVar "fields")) (EVar "values")))) (ELit (LString " }"))))
(DTypeSig false "renderFields" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "String")))))
(DFunDef false "renderFields" (PWild (PList) (PList)) (ELit (LString "")))
(DFunDef false "renderFields" ((PVar "env") (PCons (PTuple PWild (PVar "plan")) (PVar "plans")) (PCons (PVar "value") (PVar "values"))) (EBlock (DoLet false false (PVar "rendered") (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "plans")) (EApp (EVar "isEmptyL") (EVar "values"))) (EVar "rendered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "rendered"))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "renderFields") (EVar "env")) (EVar "plans")) (EVar "values")))) (ELit (LString "")))))))
(DFunDef false "renderFields" (PWild PWild PWild) (ELit (LString "<value>")))
(DTypeSig false "renderNamedFields" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "String")))))
(DFunDef false "renderNamedFields" (PWild (PList) PWild) (ELit (LString "")))
(DFunDef false "renderNamedFields" ((PVar "env") (PCons (PTuple (PCon "Some" (PVar "name")) (PVar "plan")) (PVar "rest")) (PVar "values")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "values")) (arm (PCon "Some" (PVar "value")) () (EBlock (DoLet false false (PVar "rendered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value")))) (ELit (LString "")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rest")) (EVar "rendered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "rendered"))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "renderNamedFields") (EVar "env")) (EVar "rest")) (EVar "values")))) (ELit (LString ""))))))) (arm (PCon "None") () (EBinOp "++" (EVar "name") (ELit (LString " = <value>"))))))
(DFunDef false "renderNamedFields" (PWild (PCons (PTuple (PCon "None") PWild) PWild) PWild) (ELit (LString "<value>")))
(DTypeSig false "carrierArgs" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "carrierArgs" ((PVar "carrier")) (EApp (EApp (EVar "carrierArgsGo") (EListLit)) (EVar "carrier")))
(DTypeSig false "carrierArgsGo" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "carrierArgsGo" ((PVar "acc") (PCon "TyApp" (PVar "head") (PVar "arg"))) (EApp (EApp (EVar "carrierArgsGo") (EBinOp "::" (EVar "arg") (EVar "acc"))) (EVar "head")))
(DFunDef false "carrierArgsGo" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "displayCarrierPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "GenPlan"))))))
(DFunDef false "displayCarrierPlans" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "displayCarrierPlans" ((PVar "env") (PCons (PVar "ty") (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planFor") (EVar "env")) (ELit (LString ""))) (ELit (LString "display"))) (EVar "ty")) (EApp (EApp (EVar "displayCarrierPlans") (EVar "env")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "plan")) (PCon "Some" (PVar "plans"))) () (EApp (EVar "Some") (EBinOp "::" (EVar "plan") (EVar "plans")))) (arm PWild () (EVar "None"))))
(DTypeSig true "hasProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasProps" ((PVar "decls")) (EApp (EApp (EVar "anyDecl") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "anyDecl" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "anyDecl" (PWild (PList)) (EVar "False"))
(DFunDef false "anyDecl" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "p") (EVar "d")) (EApp (EApp (EVar "anyDecl") (EVar "p")) (EVar "rest"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" false) (mem "PropParam" false) (mem "Ty" true))))
(DUse false (UseAlias ("u32") "U32"))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "apply" false) (mem "eval" false) (mem "extendEnv" false) (mem "force" false) (mem "lookupEnv" false) (mem "lookupRuntimeBinding" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "lookupAssoc" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "anyList" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("tools" "prop_plan") ((mem "deleteEach" false) (mem "prepend" false) (mem "prependBefore" false) (mem "PlanEnv" true) (mem "PlanError" false) (mem "PlanModule" false) (mem "TypeKey" true) (mem "GenPlan" true) (mem "CustomPlan" true) (mem "PlanDef" true) (mem "PlanCtor" true) (mem "PlanVisibility" true) (mem "planFor" false) (mem "planErrorText" false) (mem "planDef" false) (mem "instantiateCtor" false) (mem "buildPlanEnv" false) (mem "buildPlanEnvModules" false) (mem "listLengthBound" false) (mem "ctorWeights" false) (mem "optionWeights" false) (mem "resultWeights" false) (mem "intMin" false) (mem "intMax" false) (mem "customPlansReachable" false))))
(DTypeSig false "substringMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substringMatch" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig false "propRngStateRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "propRngStateRef" () (EApp (EVar "Ref") (ELit (LInt 123456789))))
(DTypeSig false "propSeedRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "propSeedRef" () (EApp (EVar "Ref") (ELit (LInt 123456789))))
(DTypeSig false "customRngStateRef" (TyApp (TyCon "Ref") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "customRngStateRef" () (EApp (EVar "Ref") (ETuple (ELit (LInt 0)) (ELit (LInt 0)))))
(DTypeSig false "customRngReadyRef" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "customRngReadyRef" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "customSeedRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "customSeedRef" () (EApp (EVar "Ref") (ELit (LInt 123456789))))
(DTypeSig true "seedPropRng" (TyFun (TyCon "Int") (TyCon "Unit")))
(DFunDef false "seedPropRng" ((PVar "n")) (EBlock (DoLet false false (PVar "normalized") (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (ELit (LInt 2147483648))) (ELit (LInt 2147483648))) (ELit (LInt 2147483648)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "propRngStateRef")) (EVar "normalized"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "propSeedRef")) (EVar "n"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customSeedRef")) (EVar "normalized"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customRngReadyRef")) (EVar "False")))))
(DTypeSig false "beginCustomPropStream" (TyFun (TyCon "Int") (TyCon "Unit")))
(DFunDef false "beginCustomPropStream" ((PVar "seed")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "customSeedRef")) (EVar "seed"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customRngReadyRef")) (EVar "False")))))
(DTypeSig true "propSeedValue" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "propSeedValue" (PWild) (EUnOp "!" (EVar "propSeedRef")))
(DTypeSig false "rngNextLocal" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "rngNextLocal" (PWild) (EBlock (DoLet false false (PVar "s") (EBinOp "%" (EBinOp "+" (EBinOp "*" (EUnOp "!" (EVar "propRngStateRef")) (ELit (LInt 1103515245))) (ELit (LInt 12345))) (ELit (LInt 2147483648)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "propRngStateRef")) (EVar "s"))) (DoLet false false (PVar "h1") (EAnnot (EApp (EMethodRef "fromInt") (EApp (EApp (EVar "bitXor") (EVar "s")) (EApp (EApp (EVar "shiftRight") (EVar "s")) (ELit (LInt 16))))) (TyCon "U32"))) (DoLet false false (PVar "h2") (EBinOp "*" (EVar "h1") (ELit (LInt 2246822507)))) (DoLet false false (PVar "h3") (EApp (EApp (EVar "U32.bitXor") (EVar "h2")) (EApp (EApp (EVar "U32.shiftRight") (EVar "h2")) (ELit (LInt 13))))) (DoLet false false (PVar "h4") (EBinOp "*" (EVar "h3") (ELit (LInt 3266489909)))) (DoExpr (EApp (EVar "U32.toInt") (EApp (EApp (EVar "U32.bitXor") (EVar "h4")) (EApp (EApp (EVar "U32.shiftRight") (EVar "h4")) (ELit (LInt 16))))))))
(DTypeSig false "randIntRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "randIntRange" ((PVar "lo") (PVar "hi")) (EBlock (DoLet false false (PVar "range") (EBinOp "+" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<=" (EVar "range") (ELit (LInt 0))) (EVar "lo") (EBinOp "+" (EVar "lo") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (EVar "range")))))))
(DTypeSig true "randBoolL" (TyFun (TyCon "Unit") (TyCon "Bool")))
(DFunDef false "randBoolL" (PWild) (EBinOp "==" (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2))) (ELit (LInt 1))))
(DData Public "PropHelper" () ((variant "PropHelper" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DData Public "GenEnv" () ((variant "GenEnv" (ConPos (TyCon "PlanEnv") (TyApp (TyCon "OrdMap") (TyCon "PropHelper"))))) ())
(DTypeSig true "buildGenEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "GenEnv"))))
(DFunDef false "buildGenEnv" (PWild (PVar "allDecls")) (EApp (EApp (EVar "GenEnv") (EApp (EVar "buildPlanEnv") (EVar "allDecls"))) (EVar "omEmpty")))
(DTypeSig false "buildGenEnvWithPlan" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "PlanEnv") (TyCon "GenEnv"))))
(DFunDef false "buildGenEnvWithPlan" (PWild (PVar "planEnv")) (EApp (EApp (EVar "GenEnv") (EVar "planEnv")) (EVar "omEmpty")))
(DTypeSig true "buildGenEnvWithHelpers" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyCon "GenEnv")))))
(DFunDef false "buildGenEnvWithHelpers" (PWild (PVar "planEnv") (PVar "helpers")) (EApp (EApp (EVar "GenEnv") (EVar "planEnv")) (EApp (EApp (EVar "helperMap") (EVar "helpers")) (EVar "omEmpty"))))
(DTypeSig false "helperMap" (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "PropHelper")) (TyApp (TyCon "OrdMap") (TyCon "PropHelper")))))
(DFunDef false "helperMap" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "helperMap" ((PCons (PAs "helper" (PCon "PropHelper" (PVar "word") PWild PWild)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "helperMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "helper")) (EVar "acc"))))
(DTypeSig false "genFloat" (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "genFloat" (PWild) (EBlock (DoLet false false (PVar "r") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2000001)))) (DoExpr (EApp (EVar "VFloat") (EBinOp "-" (EBinOp "*" (EApp (EVar "intToFloat") (EVar "r")) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 1000000.0)))) (ELit (LFloat 1.0)))))))
(DTypeSig false "genCharStr" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genCharStr" (PWild) (EMatch (EApp (EVar "charFromCode") (EBinOp "+" (ELit (LInt 32)) (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 95))))) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "charToStr") (EVar "c"))) (arm (PCon "None") () (ELit (LString " ")))))
(DTypeSig false "genString" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genString" (PWild) (EApp (EVar "stringConcat") (EApp (EVar "genStringGo") (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (ELit (LInt 10))))))
(DTypeSig false "genStringGo" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "genStringGo" ((PLit (LInt 0))) (EListLit))
(DFunDef false "genStringGo" ((PVar "n")) (EBinOp "::" (EApp (EVar "genCharStr") (ELit LUnit)) (EApp (EVar "genStringGo") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "shrinkInt" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "shrinkInt" ((PLit (LInt 0))) (EListLit))
(DFunDef false "shrinkInt" ((PVar "n")) (EBlock (DoLet false false (PVar "cands") (EListLit (ELit (LInt 0)) (EBinOp "/" (EVar "n") (ELit (LInt 2))) (EBinOp "+" (EVar "n") (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "VInt")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "n")))) (EVar "cands"))))))
(DTypeSig false "checkProp" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "checkProp" ((PVar "rootEnv") (PVar "body") (PVar "inputs")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "extendEnv") (EVar "rootEnv")) (EVar "inputs"))) (DoExpr (EMatch (EApp (EVar "force") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))) (arm (PCon "VBool" (PVar "b")) () (EVar "b")) (arm PWild () (EVar "False"))))))
(DData Public "PropOutcome" ("v") ((variant "PropPassed" (ConPos)) (variant "PropFailed" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "v"))) (TyCon "Bool")))) ())
(DTypeSig false "lineOfPropName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int"))))
(DFunDef false "lineOfPropName" ((PVar "name") (PVar "propLines")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "propLines")) (arm (PCon "Some" (PVar "l")) () (EVar "l")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "propLocPrefix" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "propLocPrefix" (PWild (PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "propLocPrefix" ((PVar "target") (PVar "line")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))))
(DTypeSig false "runProp" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyEffect ("IO") (Some "e") (TyCon "Bool")))))))))
(DFunDef false "runProp" ((PVar "genEnv") (PVar "evalEnv") (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "maxTests") (PVar "target") (PVar "propLines")) (EBlock (DoLet false false (PVar "line") (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "propLocPrefix") (EVar "target")) (EVar "line")))) (ELit (LString "Testing "))) (EApp (EMethodRef "display") (EApp (EVar "escStrLocal") (EVar "name")))) (ELit (LString " ... "))))) (DoLet false false (PVar "seedAtStart") (EUnOp "!" (EVar "propRngStateRef"))) (DoLet false false (PVar "rootEnv") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EVar "evalEnv"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "planPropParams") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "name")) (EVar "params")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "ERROR: ")) (EApp (EVar "planErrorText") (EVar "e"))))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "plans")) () (EMatch (EApp (EApp (EApp (EVar "helperFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "plans")) (arm (PCon "Some" (PVar "detail")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "ERROR: ")) (EVar "detail")))) (DoExpr (EVar "False")))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "beginCustomPropStream") (EVar "seedAtStart"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (ELit (LInt 1))) (arm (PCon "PropPassed") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "OK (")) (EApp (EVar "intToString") (EVar "maxTests"))) (ELit (LString " tests)"))))) (DoExpr (EVar "True")))) (arm (PCon "PropFailed" (PVar "run") (PVar "shrunk") (PVar "fuelExhausted")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAILED after ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "run")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EIf (EBinOp "==" (EVar "run") (ELit (LInt 1))) (ELit (LString " test")) (ELit (LString " tests"))))) (ELit (LString ""))))) (DoLet false false PWild (EIf (EVar "fuelExhausted") (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "  WARNING: shrink fuel exhausted after ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "shrinkFuel")))) (ELit (LString " steps; the counterexample below may not be minimal, and a shrink arm is probably cycling (see #1307).")))) (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  Seed: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "seedAtStart")))) (ELit (LString " (rerun with: medaka test --seed "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "seedAtStart")))) (ELit (LString " --filter "))) (EApp (EMethodRef "display") (EApp (EVar "escStrLocal") (EVar "name")))) (ELit (LString " <file>)"))))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  Counterexample:")))) (DoLet false false PWild (EApp (EVar "printCounterexample") (EVar "shrunk"))) (DoExpr (EVar "False"))))))))))))))
(DFunDef false "runProp" ((PVar "_genEnv") (PVar "_evalEnv") (PVar "_decl") (PVar "_maxTests") (PVar "_target") (PVar "_propLines")) (EVar "True"))
(DTypeSig false "findFailure" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "findFailure" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run")) (EIf (EBinOp ">" (EVar "run") (EVar "maxTests")) (EVar "PropPassed") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "inputs") (EApp (EApp (EApp (EVar "genInputs") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailureStep") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EVar "run")) (EVar "inputs")) (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "inputs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findFailurePlanned" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e"))))))))))))
(DFunDef false "findFailurePlanned" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "plans") (PVar "body") (PVar "maxTests") (PVar "run")) (EIf (EBinOp ">" (EVar "run") (EVar "maxTests")) (EVar "PropPassed") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "inputs") (EApp (EApp (EApp (EApp (EVar "genInputsPlanned") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "plans"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "inputs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailurePlanned") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "plans")) (EVar "body")) (EVar "maxTests")) (EBinOp "+" (EVar "run") (ELit (LInt 1)))) (EBlock (DoLet false false (PTuple (PVar "shrunk") (PVar "fuelExhausted")) (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoop") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "inputs"))) (DoExpr (EApp (EApp (EApp (EVar "PropFailed") (EVar "run")) (EVar "shrunk")) (EVar "fuelExhausted"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findFailureStep" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Bool") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "findFailureStep" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run") PWild (PCon "True")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EBinOp "+" (EVar "run") (ELit (LInt 1)))))
(DFunDef false "findFailureStep" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") PWild (PVar "run") (PVar "inputs") (PCon "False")) (EBlock (DoLet false false (PTuple (PVar "shrunk") (PVar "fuelExhausted")) (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoop") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "inputs"))) (DoExpr (EApp (EApp (EApp (EVar "PropFailed") (EVar "run")) (EVar "shrunk")) (EVar "fuelExhausted")))))
(DTypeSig false "genInputs" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genInputs" (PWild PWild (PList)) (EListLit))
(DFunDef false "genInputs" ((PVar "genEnv") (PVar "evalEnv") (PCons (PCon "PropParam" (PVar "x") PWild (PVar "ty")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "x") (EApp (EApp (EApp (EVar "genParam") (EVar "genEnv")) (EVar "evalEnv")) (EVar "ty"))) (EApp (EApp (EApp (EVar "genInputs") (EVar "genEnv")) (EVar "evalEnv")) (EVar "rest"))))
(DTypeSig false "genInputsPlanned" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "genInputsPlanned" (PWild PWild (PList) (PList)) (EListLit))
(DFunDef false "genInputsPlanned" ((PVar "genEnv") (PVar "evalEnv") (PCons (PCon "PropParam" (PVar "x") PWild PWild) (PVar "rest")) (PCons (PVar "plan") (PVar "plans"))) (EBinOp "::" (ETuple (EVar "x") (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "genEnv")) (EVar "evalEnv")) (ELit (LInt 0))) (EVar "plan"))) (EApp (EApp (EApp (EApp (EVar "genInputsPlanned") (EVar "genEnv")) (EVar "evalEnv")) (EVar "rest")) (EVar "plans"))))
(DFunDef false "genInputsPlanned" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "property runner: prepared parameter plan mismatch"))))
(DTypeSig false "genParam" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Ty") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "genParam" ((PAs "ge" (PCon "GenEnv" (PVar "planEnv") PWild)) (PVar "evalEnv") (PVar "ty")) (EMatch (EApp (EApp (EApp (EApp (EVar "planFor") (EVar "planEnv")) (ELit (LString ""))) (ELit (LString "property parameter"))) (EVar "ty")) (arm (PCon "Ok" (PVar "plan")) () (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "evalEnv")) (ELit (LInt 0))) (EVar "plan"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EApp (EVar "planErrorText") (EVar "e"))))))
(DTypeSig false "genFromPlan" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GInt")) (EApp (EVar "VInt") (EApp (EApp (EVar "randIntRange") (EVar "intMin")) (EVar "intMax"))))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GBool")) (EApp (EVar "VBool") (EApp (EVar "randBoolL") (ELit LUnit))))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GFloat")) (EApp (EVar "genFloat") (ELit LUnit)))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GChar")) (EApp (EVar "VChar") (EApp (EVar "genCharStr") (ELit LUnit))))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GString")) (EApp (EVar "VString") (EApp (EVar "genString") (ELit LUnit))))
(DFunDef false "genFromPlan" (PWild PWild PWild (PCon "GUnit")) (EVar "VUnit"))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PCon "GList" (PVar "plan"))) (EApp (EVar "VList") (EApp (EApp (EApp (EApp (EApp (EVar "genPlanList") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "listLengthBound") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "depth")) (EVar "plan"))))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PCon "GArray" (PVar "plan"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EVar "genPlanList") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "listLengthBound") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "depth")) (EVar "plan")))))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PCon "GOption" (PVar "plan"))) (EApp (EApp (EApp (EApp (EApp (EVar "chooseOption") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan")) (EApp (EApp (EApp (EVar "optionWeights") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "depth")) (EVar "plan"))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PCon "GResult" (PVar "err") (PVar "ok"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chooseResult") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "err")) (EVar "ok")) (EApp (EApp (EApp (EApp (EVar "resultWeights") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "depth")) (EVar "err")) (EVar "ok"))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PCon "GTuple" (PVar "plans"))) (EApp (EVar "VTuple") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth"))) (EVar "plans"))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") (PVar "depth") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild))) (EMatch (EApp (EApp (EVar "planDef") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EApp (EVar "genPlannedCtor") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "nominal")) (EApp (EApp (EVar "choosePlanCtor") (EVar "ctors")) (EApp (EApp (EApp (EVar "ctorWeights") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "nominal")) (EVar "depth"))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EApp (EVar "planErrorText") (EVar "e"))))))
(DFunDef false "genFromPlan" ((PVar "ge") (PVar "env") PWild (PAs "custom" (PCon "GCustom" PWild))) (EApp (EApp (EApp (EVar "drawCustomArbitrary") (EVar "ge")) (EVar "env")) (EVar "custom")))
(DTypeSig false "genEnvPlan" (TyFun (TyCon "GenEnv") (TyCon "PlanEnv")))
(DFunDef false "genEnvPlan" ((PCon "GenEnv" (PVar "planEnv") PWild)) (EVar "planEnv"))
(DTypeSig false "drawCustomArbitrary" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "drawCustomArbitrary" ((PVar "ge") (PVar "env") (PVar "custom")) (EBlock (DoLet false false (PVar "programState") (EApp (EVar "readRandomState") (EVar "env"))) (DoLet false false PWild (EApp (EVar "ensureCustomRandomState") (EVar "env"))) (DoLet false false (PTuple (PVar "hi") (PVar "lo")) (EUnOp "!" (EVar "customRngStateRef"))) (DoLet false false PWild (EApp (EApp (EVar "restoreRandomStateValue") (EVar "env")) (EApp (EApp (EVar "VU64") (EVar "hi")) (EVar "lo")))) (DoLet false false (PVar "value") (EMatch (EApp (EApp (EVar "customHelper") (EVar "ge")) (EVar "custom")) (arm (PCon "Some" (PCon "PropHelper" PWild (PVar "genName") PWild)) () (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "genName")))) (EVar "VUnit")))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "property runner: missing selected typed custom helper")))))) (DoLet false false (PVar "customState") (EApp (EVar "readRandomState") (EVar "env"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customRngStateRef")) (EApp (EVar "u64Pair") (EVar "customState")))) (DoLet false false PWild (EApp (EApp (EVar "restoreRandomStateValue") (EVar "env")) (EVar "programState"))) (DoExpr (EVar "value"))))
(DTypeSig false "customHelper" (TyFun (TyCon "GenEnv") (TyFun (TyCon "GenPlan") (TyApp (TyCon "Option") (TyCon "PropHelper")))))
(DFunDef false "customHelper" ((PCon "GenEnv" PWild (PVar "helpers")) (PCon "GCustom" (PCon "CustomPlan" PWild PWild (PVar "word")))) (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "helpers")))
(DFunDef false "customHelper" (PWild PWild) (EVar "None"))
(DTypeSig false "helperFailure" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "helperFailure" ((PVar "ge") (PVar "env") (PVar "plans")) (EApp (EApp (EApp (EVar "helperFailureCustoms") (EVar "ge")) (EApp (EVar "envBindingNames") (EVar "env"))) (EApp (EApp (EVar "customPlansReachable") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "plans"))))
(DTypeSig false "helperFailureCustoms" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "helperFailureCustoms" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "helperFailureCustoms" ((PVar "ge") (PVar "names") (PCons (PVar "custom") (PVar "rest"))) (EMatch (EApp (EApp (EVar "customHelper") (EVar "ge")) (EApp (EVar "GCustom") (EVar "custom"))) (arm (PCon "Some" (PCon "PropHelper" PWild (PVar "genName") (PVar "shrinkName"))) () (EMatch (ETuple (EApp (EApp (EVar "omHasKey") (EVar "genName")) (EVar "names")) (EApp (EApp (EVar "omHasKey") (EVar "shrinkName")) (EVar "names"))) (arm (PTuple (PCon "True") (PCon "True")) () (EApp (EApp (EApp (EVar "helperFailureCustoms") (EVar "ge")) (EVar "names")) (EVar "rest"))) (arm PWild () (EApp (EVar "Some") (ELit (LString "selected typed custom helper binding is unavailable")))))) (arm (PCon "None") () (EApp (EVar "Some") (ELit (LString "selected typed custom helper is unavailable"))))))
(DTypeSig false "envBindingNames" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "envBindingNames" ((PCon "EvalEnv" (PVar "frames"))) (EApp (EApp (EVar "bindingNamesFrames") (EVar "frames")) (EVar "omEmpty")))
(DTypeSig false "bindingNamesFrames" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindingNamesFrames" ((PList) (PVar "names")) (EVar "names"))
(DFunDef false "bindingNamesFrames" ((PCons (PVar "frame") (PVar "rest")) (PVar "names")) (EApp (EApp (EVar "bindingNamesFrames") (EVar "rest")) (EApp (EApp (EVar "bindingNamesFrame") (EVar "frame")) (EVar "names"))))
(DTypeSig false "bindingNamesFrame" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindingNamesFrame" ((PList) (PVar "names")) (EVar "names"))
(DFunDef false "bindingNamesFrame" ((PCons (PTuple (PVar "name") PWild) (PVar "rest")) (PVar "names")) (EApp (EApp (EVar "bindingNamesFrame") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "names"))))
(DTypeSig false "ensureCustomRandomState" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "ensureCustomRandomState" ((PVar "env")) (EIf (EUnOp "!" (EVar "customRngReadyRef")) (ELit LUnit) (EBlock (DoLet false false (PVar "programState") (EApp (EVar "readRandomState") (EVar "env"))) (DoLet false false PWild (EApp (EApp (EVar "callRandomSetSeed") (EVar "env")) (EUnOp "!" (EVar "customSeedRef")))) (DoLet false false (PVar "seeded") (EApp (EVar "readRandomState") (EVar "env"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customRngStateRef")) (EApp (EVar "u64Pair") (EVar "seeded")))) (DoLet false false PWild (EApp (EApp (EVar "restoreRandomStateValue") (EVar "env")) (EVar "programState"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "customRngReadyRef")) (EVar "True"))))))
(DTypeSig false "readRandomState" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "readRandomState" ((PVar "env")) (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupRuntimeBinding") (EVar "env")) (ELit (LString "randomState"))))) (EVar "VUnit"))))
(DTypeSig false "restoreRandomStateValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "restoreRandomStateValue" ((PVar "env") (PVar "state")) (EMatch (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupRuntimeBinding") (EVar "env")) (ELit (LString "restoreRandomState"))))) (EVar "state"))) (arm (PCon "VUnit") () (ELit LUnit)) (arm PWild () (EApp (EVar "panic") (ELit (LString "property runner: restoreRandomState returned a non-Unit value"))))))
(DTypeSig false "callRandomSetSeed" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "callRandomSetSeed" ((PVar "env") (PVar "seed")) (EMatch (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupRuntimeBinding") (EVar "env")) (ELit (LString "setSeed"))))) (EApp (EVar "VInt") (EVar "seed")))) (arm (PCon "VUnit") () (ELit LUnit)) (arm PWild () (EApp (EVar "panic") (ELit (LString "property runner: setSeed returned a non-Unit value"))))))
(DTypeSig false "u64Pair" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "u64Pair" ((PCon "VU64" (PVar "hi") (PVar "lo"))) (ETuple (EVar "hi") (EVar "lo")))
(DFunDef false "u64Pair" (PWild) (EApp (EVar "panic") (ELit (LString "property runner: randomState returned a non-U64 value"))))
(DTypeSig false "genPlanList" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "genPlanList" (PWild PWild PWild PWild (PLit (LInt 0))) (EListLit))
(DFunDef false "genPlanList" ((PVar "ge") (PVar "env") (PVar "depth") (PVar "plan") (PVar "n")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan")) (EApp (EApp (EApp (EApp (EApp (EVar "genPlanList") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "chooseOption" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "chooseOption" ((PVar "ge") (PVar "env") (PVar "depth") (PVar "plan") (PVar "weights")) (EIf (EApp (EVar "chooseWeight") (EVar "weights")) (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)) (EApp (EApp (EVar "VCon") (ELit (LString "Some"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan"))))))
(DTypeSig false "chooseResult" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "chooseResult" ((PVar "ge") (PVar "env") (PVar "depth") (PVar "err") (PVar "ok") (PVar "weights")) (EIf (EApp (EVar "chooseWeight") (EVar "weights")) (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "err")))) (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "ok"))))))
(DTypeSig false "chooseWeight" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "chooseWeight" ((PCons (PVar "first") (PCons (PVar "second") PWild))) (EBlock (DoLet false false (PVar "total") (EBinOp "+" (EVar "first") (EVar "second"))) (DoExpr (EIf (EBinOp "<=" (EVar "total") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "property runner: planner produced no finite branch"))) (EBinOp "<" (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EVar "total") (ELit (LInt 1)))) (EVar "first"))))))
(DFunDef false "chooseWeight" (PWild) (EApp (EVar "panic") (ELit (LString "property runner: planner returned malformed branch weights"))))
(DTypeSig false "choosePlanCtor" (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "PlanCtor"))))
(DFunDef false "choosePlanCtor" ((PList) PWild) (EApp (EVar "panic") (ELit (LString "property runner: nominal type has no constructors"))))
(DFunDef false "choosePlanCtor" ((PVar "ctors") (PVar "weights")) (EBlock (DoLet false false (PVar "total") (EApp (EVar "sumWeights") (EVar "weights"))) (DoExpr (EIf (EBinOp "<=" (EVar "total") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "property runner: planner produced no finite constructor"))) (EApp (EApp (EApp (EVar "choosePlanCtorAt") (EVar "ctors")) (EVar "weights")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EVar "total") (ELit (LInt 1)))))))))
(DTypeSig false "choosePlanCtorAt" (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "PlanCtor")))))
(DFunDef false "choosePlanCtorAt" ((PCons (PVar "ctor") PWild) (PList) PWild) (EVar "ctor"))
(DFunDef false "choosePlanCtorAt" ((PCons (PVar "ctor") PWild) (PCons (PVar "weight") PWild) (PVar "n")) (EIf (EBinOp "<" (EVar "n") (EVar "weight")) (EVar "ctor") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "choosePlanCtorAt" ((PCons PWild (PVar "ctors")) (PCons (PVar "weight") (PVar "weights")) (PVar "n")) (EApp (EApp (EApp (EVar "choosePlanCtorAt") (EVar "ctors")) (EVar "weights")) (EBinOp "-" (EVar "n") (EVar "weight"))))
(DFunDef false "choosePlanCtorAt" ((PList) PWild PWild) (EApp (EVar "panic") (ELit (LString "property runner: constructor weights were empty"))))
(DTypeSig false "sumWeights" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "sumWeights" ((PList)) (ELit (LInt 0)))
(DFunDef false "sumWeights" ((PCons (PVar "n") (PVar "rest"))) (EBinOp "+" (EVar "n") (EApp (EVar "sumWeights") (EVar "rest"))))
(DTypeSig false "nthList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "Int") (TyVar "a"))))
(DFunDef false "nthList" ((PCons (PVar "x") PWild) (PLit (LInt 0))) (EVar "x"))
(DFunDef false "nthList" ((PCons PWild (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "nthList") (EVar "rest")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))
(DFunDef false "nthList" ((PList) PWild) (EApp (EVar "panic") (ELit (LString "property runner: index out of range"))))
(DTypeSig false "genPlannedCtor" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genPlannedCtor" ((PVar "ge") (PVar "env") (PVar "depth") (PVar "nominal") (PAs "ctor" (PCon "PlanCtor" PWild (PVar "runtime") PWild))) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EVar "plannedCtorValue") (EVar "runtime")) (EApp (EApp (EApp (EApp (EVar "genPlannedFields") (EVar "ge")) (EVar "env")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "fields")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EApp (EVar "planErrorText") (EVar "e"))))))
(DTypeSig false "genPlannedFields" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "genPlannedFields" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "genPlannedFields" ((PVar "ge") (PVar "env") (PVar "depth") (PCons (PTuple (PVar "name") (PVar "plan")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EVar "genFromPlan") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "plan"))) (EApp (EApp (EApp (EApp (EVar "genPlannedFields") (EVar "ge")) (EVar "env")) (EVar "depth")) (EVar "rest"))))
(DTypeSig false "plannedCtorValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "plannedCtorValue" ((PVar "runtime") (PList)) (EApp (EApp (EVar "VCon") (EVar "runtime")) (EListLit)))
(DFunDef false "plannedCtorValue" ((PVar "runtime") (PCons (PTuple (PCon "Some" (PVar "name")) (PVar "value")) (PVar "rest"))) (EApp (EApp (EVar "VRecord") (EVar "runtime")) (EBinOp "::" (ETuple (EVar "name") (EVar "value")) (EApp (EVar "namedPlanFields") (EVar "rest")))))
(DFunDef false "plannedCtorValue" ((PVar "runtime") (PCons (PTuple (PCon "None") (PVar "value")) (PVar "rest"))) (EApp (EApp (EVar "VCon") (EVar "runtime")) (EBinOp "::" (EVar "value") (EApp (EVar "positionalPlanFields") (EVar "rest")))))
(DTypeSig false "namedPlanFields" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "namedPlanFields" ((PList)) (EListLit))
(DFunDef false "namedPlanFields" ((PCons (PTuple (PCon "Some" (PVar "name")) (PVar "value")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EVar "value")) (EApp (EVar "namedPlanFields") (EVar "rest"))))
(DFunDef false "namedPlanFields" ((PCons (PTuple (PCon "None") PWild) PWild)) (EApp (EVar "panic") (ELit (LString "property runner: mixed positional and named constructor fields"))))
(DTypeSig false "positionalPlanFields" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "positionalPlanFields" ((PList)) (EListLit))
(DFunDef false "positionalPlanFields" ((PCons (PTuple (PCon "None") (PVar "value")) (PVar "rest"))) (EBinOp "::" (EVar "value") (EApp (EVar "positionalPlanFields") (EVar "rest"))))
(DFunDef false "positionalPlanFields" ((PCons (PTuple (PCon "Some" PWild) PWild) PWild)) (EApp (EVar "panic") (ELit (LString "property runner: mixed positional and named constructor fields"))))
(DTypeSig false "shrinkForParam" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "shrinkForParam" ((PVar "ge") (PVar "env") (PVar "ty") (PVar "value")) (EMatch (EApp (EApp (EApp (EApp (EVar "planFor") (EApp (EVar "genEnvPlan") (EVar "ge"))) (ELit (LString ""))) (ELit (LString "property parameter"))) (EVar "ty")) (arm (PCon "Ok" (PAs "custom" (PCon "GCustom" PWild))) () (EMatch (EApp (EApp (EVar "customHelper") (EVar "ge")) (EVar "custom")) (arm (PCon "Some" (PCon "PropHelper" PWild PWild (PVar "shrinkName"))) () (EMatch (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "shrinkName")))) (EVar "value"))) (arm (PCon "VList" (PVar "smaller")) () (EVar "smaller")) (arm PWild () (EApp (EVar "panic") (ELit (LString "property runner: typed custom shrink returned a non-List value")))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "property runner: missing selected typed custom helper")))))) (arm (PCon "Ok" (PVar "plan")) () (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "value"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EApp (EVar "planErrorText") (EVar "e"))))))
(DTypeSig false "shrinkCustom" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "shrinkCustom" ((PVar "ge") (PVar "env") (PVar "custom") (PVar "value")) (EMatch (EApp (EApp (EVar "customHelper") (EVar "ge")) (EVar "custom")) (arm (PCon "Some" (PCon "PropHelper" PWild PWild (PVar "shrinkName"))) () (EMatch (EApp (EVar "force") (EApp (EApp (EVar "apply") (EApp (EVar "force") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "shrinkName")))) (EVar "value"))) (arm (PCon "VList" (PVar "smaller")) () (EVar "smaller")) (arm PWild () (EApp (EVar "panic") (ELit (LString "property runner: typed custom shrink returned a non-List value")))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "property runner: missing selected typed custom helper"))))))
(DTypeSig false "structuralShrink" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GInt") (PCon "VInt" (PVar "n"))) (EApp (EVar "shrinkInt") (EVar "n")))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GBool") (PCon "VBool" (PCon "True"))) (EListLit (EApp (EVar "VBool") (EVar "False"))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GBool") PWild) (EListLit))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GFloat") (PCon "VFloat" (PVar "x"))) (EIf (EBinOp "==" (EVar "x") (ELit (LFloat 0.0))) (EListLit) (EListLit (EApp (EVar "VFloat") (ELit (LFloat 0.0))) (EApp (EVar "VFloat") (EBinOp "/" (EVar "x") (ELit (LFloat 2.0)))))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GString") (PCon "VString" (PVar "s"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EListLit) (EListLit (EApp (EVar "VString") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))) (EVar "s"))))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GChar") (PCon "VChar" PWild)) (EListLit))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GUnit") PWild) (EListLit))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GList" (PVar "plan")) (PCon "VList" (PVar "values"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "VList")) (EApp (EVar "deleteEach") (EVar "values"))) (EApp (EApp (EMethodRef "map") (EVar "VList")) (EApp (EApp (EApp (EApp (EVar "shrinkElements") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "values")))))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GArray" (PVar "plan")) (PCon "VArray" (PVar "values"))) (EBlock (DoLet false false (PVar "xs") (EApp (EMethodRef "toList") (EVar "values"))) (DoExpr (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "xs2")) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EVar "xs2"))))) (EApp (EVar "deleteEach") (EVar "xs"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "xs2")) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EVar "xs2"))))) (EApp (EApp (EApp (EApp (EVar "shrinkElements") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "xs")))))))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GOption" (PVar "plan")) (PCon "VCon" (PLit (LString "Some")) (PList (PVar "value")))) (EBinOp "::" (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EApp (EApp (EVar "VCon") (ELit (LString "Some"))) (EListLit (EVar "v"))))) (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "value")))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GOption" PWild) PWild) (EListLit))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GResult" (PVar "err") PWild) (PCon "VCon" (PLit (LString "Err")) (PList (PVar "value")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EVar "v"))))) (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "err")) (EVar "value"))))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GResult" PWild (PVar "ok")) (PCon "VCon" (PLit (LString "Ok")) (PList (PVar "value")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EVar "v"))))) (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "ok")) (EVar "value"))))
(DFunDef false "structuralShrink" (PWild PWild (PCon "GResult" PWild PWild) PWild) (EListLit))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PCon "GTuple" (PVar "plans")) (PCon "VTuple" (PVar "values"))) (EApp (EApp (EMethodRef "map") (EVar "VTuple")) (EApp (EApp (EApp (EApp (EVar "shrinkPlanValues") (EVar "ge")) (EVar "env")) (EVar "plans")) (EVar "values"))))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild)) (PVar "value")) (EApp (EApp (EApp (EApp (EApp (EVar "shrinkNominal") (EVar "ge")) (EVar "env")) (EVar "nominal")) (EVar "key")) (EVar "value")))
(DFunDef false "structuralShrink" ((PVar "ge") (PVar "env") (PAs "custom" (PCon "GCustom" PWild)) (PVar "value")) (EApp (EApp (EApp (EApp (EVar "shrinkCustom") (EVar "ge")) (EVar "env")) (EVar "custom")) (EVar "value")))
(DFunDef false "structuralShrink" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "shrinkElements" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "shrinkElements" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "shrinkElements" ((PVar "ge") (PVar "env") (PVar "plan") (PCons (PVar "value") (PVar "values"))) (EBlock (DoLet false false (PVar "here") (EApp (EApp (EMethodRef "map") (EApp (EVar "prependBefore") (EVar "values"))) (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "value")))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EMethodRef "map") (EApp (EVar "prepend") (EVar "value"))) (EApp (EApp (EApp (EApp (EVar "shrinkElements") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "values")))))))
(DTypeSig false "shrinkPlanValues" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "shrinkPlanValues" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "shrinkPlanValues" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "shrinkPlanValues" ((PVar "ge") (PVar "env") (PCons (PVar "plan") (PVar "plans")) (PCons (PVar "value") (PVar "values"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "prependBefore") (EVar "values"))) (EApp (EApp (EApp (EApp (EVar "structuralShrink") (EVar "ge")) (EVar "env")) (EVar "plan")) (EVar "value"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "prepend") (EVar "value"))) (EApp (EApp (EApp (EApp (EVar "shrinkPlanValues") (EVar "ge")) (EVar "env")) (EVar "plans")) (EVar "values")))))
(DTypeSig false "shrinkNominal" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "shrinkNominal" ((PVar "ge") (PVar "env") (PVar "nominal") (PVar "key") (PVar "value")) (EMatch (EApp (EApp (EVar "planDef") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EBinOp "++" (EApp (EVar "nullaryCtorValues") (EVar "ctors")) (EApp (EApp (EApp (EApp (EApp (EVar "shrinkNominalFields") (EVar "ge")) (EVar "env")) (EVar "nominal")) (EVar "ctors")) (EVar "value")))) (arm (PCon "Err" PWild) () (EListLit))))
(DTypeSig false "nullaryCtorValues" (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "nullaryCtorValues" ((PList)) (EListLit))
(DFunDef false "nullaryCtorValues" ((PCons (PCon "PlanCtor" PWild (PVar "runtime") (PList)) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "VCon") (EVar "runtime")) (EListLit)) (EApp (EVar "nullaryCtorValues") (EVar "rest"))))
(DFunDef false "nullaryCtorValues" ((PCons PWild (PVar "rest"))) (EApp (EVar "nullaryCtorValues") (EVar "rest")))
(DTypeSig false "shrinkNominalFields" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "shrinkNominalFields" ((PVar "ge") (PVar "env") (PVar "nominal") (PVar "ctors") (PCon "VCon" (PVar "runtime") (PVar "values"))) (EMatch (EApp (EApp (EVar "planCtorRuntime") (EVar "runtime")) (EVar "ctors")) (arm (PCon "Some" (PVar "ctor")) () (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "vs")) (EApp (EApp (EVar "VCon") (EVar "runtime")) (EVar "vs")))) (EApp (EApp (EApp (EApp (EVar "shrinkPlanValues") (EVar "ge")) (EVar "env")) (EApp (EVar "fieldPlans") (EVar "fields"))) (EVar "values")))) (arm (PCon "Err" PWild) () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DFunDef false "shrinkNominalFields" ((PVar "ge") (PVar "env") (PVar "nominal") (PVar "ctors") (PCon "VRecord" (PVar "runtime") (PVar "fields"))) (EMatch (EApp (EApp (EVar "planCtorRuntime") (EVar "runtime")) (EVar "ctors")) (arm (PCon "Some" (PVar "ctor")) () (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EApp (EVar "genEnvPlan") (EVar "ge"))) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "plans")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "vs")) (EApp (EApp (EVar "VRecord") (EVar "runtime")) (EApp (EApp (EVar "zipNames") (EApp (EVar "fieldNames") (EVar "fields"))) (EVar "vs"))))) (EApp (EApp (EApp (EApp (EVar "shrinkPlanValues") (EVar "ge")) (EVar "env")) (EApp (EVar "fieldPlans") (EVar "plans"))) (EApp (EVar "fieldValues") (EVar "fields"))))) (arm (PCon "Err" PWild) () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DFunDef false "shrinkNominalFields" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "planCtorRuntime" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyApp (TyCon "Option") (TyCon "PlanCtor")))))
(DFunDef false "planCtorRuntime" (PWild (PList)) (EVar "None"))
(DFunDef false "planCtorRuntime" ((PVar "runtime") (PCons (PAs "ctor" (PCon "PlanCtor" PWild (PVar "actual") PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EVar "runtime") (EVar "actual")) (EApp (EVar "Some") (EVar "ctor")) (EApp (EApp (EVar "planCtorRuntime") (EVar "runtime")) (EVar "rest"))))
(DTypeSig false "fieldPlans" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyApp (TyCon "List") (TyCon "GenPlan"))))
(DFunDef false "fieldPlans" ((PList)) (EListLit))
(DFunDef false "fieldPlans" ((PCons (PTuple PWild (PVar "plan")) (PVar "rest"))) (EBinOp "::" (EVar "plan") (EApp (EVar "fieldPlans") (EVar "rest"))))
(DTypeSig false "fieldNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldNames" ((PList)) (EListLit))
(DFunDef false "fieldNames" ((PCons (PTuple (PVar "name") PWild) (PVar "rest"))) (EBinOp "::" (EVar "name") (EApp (EVar "fieldNames") (EVar "rest"))))
(DTypeSig false "fieldValues" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "fieldValues" ((PList)) (EListLit))
(DFunDef false "fieldValues" ((PCons (PTuple PWild (PVar "value")) (PVar "rest"))) (EBinOp "::" (EVar "value") (EApp (EVar "fieldValues") (EVar "rest"))))
(DTypeSig false "zipNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "zipNames" ((PList) PWild) (EListLit))
(DFunDef false "zipNames" (PWild (PList)) (EListLit))
(DFunDef false "zipNames" ((PCons (PVar "name") (PVar "names")) (PCons (PVar "value") (PVar "values"))) (EBinOp "::" (ETuple (EVar "name") (EVar "value")) (EApp (EApp (EVar "zipNames") (EVar "names")) (EVar "values"))))
(DTypeSig false "printCounterexample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printCounterexample" ((PList)) (ELit LUnit))
(DFunDef false "printCounterexample" ((PCons (PTuple (PVar "x") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "ppValue") (EVar "v")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "printCounterexample") (EVar "rest")))))
(DTypeSig false "escStrLocal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStrLocal" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DTypeSig false "shrinkFuel" (TyCon "Int"))
(DFunDef false "shrinkFuel" () (ELit (LInt 10000)))
(DTypeSig false "shrinkLoop" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "Bool")))))))))
(DFunDef false "shrinkLoop" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoopFuel") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "shrinkFuel")))
(DTypeSig false "shrinkLoopFuel" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "Bool"))))))))))
(DFunDef false "shrinkLoopFuel" (PWild PWild PWild PWild (PVar "candidate") (PLit (LInt 0))) (ETuple (EVar "candidate") (EVar "True")))
(DFunDef false "shrinkLoopFuel" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "fuel")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (ELit (LInt 0))) (arm (PCon "Some" (PVar "better")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoopFuel") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "better")) (EBinOp "-" (EVar "fuel") (ELit (LInt 1))))) (arm (PCon "None") () (ETuple (EVar "candidate") (EVar "False")))))
(DTypeSig false "tryShrinkOne" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "tryShrinkOne" ((PVar "genEnv") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "listLen") (EVar "params"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PCon "PropParam" (PVar "x") PWild (PVar "ty")) (EApp (EApp (EVar "nthList") (EVar "params")) (EVar "i"))) (DoLet false false (PVar "currentV") (EApp (EApp (EVar "assocVal") (EVar "x")) (EVar "candidate"))) (DoLet false false (PVar "smaller") (EApp (EApp (EApp (EApp (EVar "shrinkForParam") (EVar "genEnv")) (EVar "evalEnv")) (EVar "ty")) (EVar "currentV"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findSmaller") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "x")) (EVar "smaller")) (arm (PCon "Some" (PVar "better")) () (EApp (EVar "Some") (EVar "better"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findSmaller" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "findSmaller" (PWild PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "findSmaller" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "x") (PCons (PVar "sv") (PVar "rest"))) (EBlock (DoLet false false (PVar "candidate2") (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "candidate"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "candidate2")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findSmaller") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "x")) (EVar "rest")) (EApp (EVar "Some") (EVar "candidate2"))))))
(DTypeSig false "assocVal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "assocVal" ((PVar "x") (PVar "kvs")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "kvs")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "prop shrink: missing binding ")) (EVar "x"))))))
(DTypeSig false "replaceVal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "replaceVal" (PWild PWild (PList)) (EListLit))
(DFunDef false "replaceVal" ((PVar "x") (PVar "sv") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "x")) (EBinOp "::" (ETuple (EVar "k") (EVar "sv")) (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isProp" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isProp" ((PCon "DProp" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isProp" (PWild) (EVar "False"))
(DTypeSig true "filterProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "filterProps" ((PVar "decls")) (EApp (EApp (EVar "filterDecls") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "filterDecls" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterDecls" (PWild (PList)) (EListLit))
(DFunDef false "filterDecls" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "d")) (EBinOp "::" (EVar "d") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "filterPropsByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterPropsByName" ((PCon "None") (PVar "decls")) (EVar "decls"))
(DFunDef false "filterPropsByName" ((PCon "Some" (PVar "sub")) (PVar "decls")) (EApp (EApp (EVar "filterDecls") (EApp (EVar "propNameMatches") (EMethodRef "sub"))) (EVar "decls")))
(DTypeSig false "propNameMatches" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "propNameMatches" ((PVar "sub") (PCon "DProp" PWild (PVar "name") PWild PWild)) (EApp (EApp (EVar "substringMatch") (EMethodRef "sub")) (EVar "name")))
(DFunDef false "propNameMatches" (PWild PWild) (EVar "False"))
(DTypeSig true "runAllProps" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") (Some "e") (TyCon "Bool"))))))))))
(DFunDef false "runAllProps" ((PVar "cases") (PVar "filterOpt") (PVar "target") (PVar "propLines") (PVar "evalEnv") (PVar "program") (PVar "allDecls")) (EBlock (DoLet false false (PVar "props") (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "program")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "props")) (EVar "True") (EBlock (DoLet false false (PVar "genEnv") (EApp (EApp (EVar "buildGenEnv") (EVar "program")) (EVar "allDecls"))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEach") (EVar "cases")) (EVar "target")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "props"))) (DoLet false false (PVar "nPass") (EApp (EVar "countTrue") (EVar "results"))) (DoLet false false (PVar "nFail") (EBinOp "-" (EApp (EVar "listLen") (EVar "results")) (EVar "nPass"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nPass")))) (ELit (LString " passed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nFail")))) (ELit (LString " failed"))))) (DoExpr (EBinOp "==" (EVar "nFail") (ELit (LInt 0)))))))))
(DTypeSig false "runEach" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") (Some "e") (TyApp (TyCon "List") (TyCon "Bool"))))))))))
(DFunDef false "runEach" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "runEach" ((PVar "cases") (PVar "target") (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProp") (EVar "genEnv")) (EVar "evalEnv")) (EVar "p")) (EVar "cases")) (EVar "target")) (EVar "propLines")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEach") (EVar "cases")) (EVar "target")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rest"))))
(DTypeSig false "countTrue" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyCon "Int")))
(DFunDef false "countTrue" ((PList)) (ELit (LInt 0)))
(DFunDef false "countTrue" ((PCons (PCon "True") (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countTrue") (EVar "rest"))))
(DFunDef false "countTrue" ((PCons (PCon "False") (PVar "rest"))) (EApp (EVar "countTrue") (EVar "rest")))
(DData Public "PropStatus" () ((variant "PropPassedResult" (ConPos)) (variant "PropFailedResult" (ConPos)) (variant "PropErroredResult" (ConPos))) ())
(DData Public "PropFailureKind" () ((variant "PropLawFalse" (ConPos)) (variant "PropCapabilityError" (ConPos)) (variant "PropBuildError" (ConPos)) (variant "PropRuntimeError" (ConPos)) (variant "PropProtocolError" (ConPos)) (variant "PropTypeError" (ConPos))) ())
(DData Public "PropRequest" () ((variant "PropRequest" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "propRequestName" (TyFun (TyCon "PropRequest") (TyCon "String")))
(DFunDef false "propRequestName" ((PCon "PropRequest" (PVar "name") PWild PWild)) (EVar "name"))
(DTypeSig true "propRequestSeed" (TyFun (TyCon "PropRequest") (TyCon "Int")))
(DFunDef false "propRequestSeed" ((PCon "PropRequest" PWild (PVar "seed") PWild)) (EVar "seed"))
(DTypeSig true "propRequestCases" (TyFun (TyCon "PropRequest") (TyCon "Int")))
(DFunDef false "propRequestCases" ((PCon "PropRequest" PWild PWild (PVar "cases"))) (EVar "cases"))
(DData Public "PropResult" () ((variant "PropResult" (ConPos (TyCon "String") (TyCon "String") (TyCon "PropStatus") (TyApp (TyCon "Option") (TyCon "PropFailureKind")) (TyCon "String") (TyCon "Int") (TyCon "Int")))) ())
(DData Public "PreparedPropRequest" () ((variant "PreparedRun" (ConPos (TyCon "PropRequest") (TyCon "Decl") (TyApp (TyCon "List") (TyCon "GenPlan")))) (variant "PreparedResult" (ConPos (TyCon "PropResult")))) ())
(DTypeSig true "propResultName" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "propResultName" ((PCon "PropResult" PWild (PVar "n") PWild PWild PWild PWild PWild)) (EVar "n"))
(DTypeSig true "propResultEngine" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "propResultEngine" ((PCon "PropResult" (PVar "e") PWild PWild PWild PWild PWild PWild)) (EVar "e"))
(DTypeSig true "propResultPassed" (TyFun (TyCon "PropResult") (TyCon "Bool")))
(DFunDef false "propResultPassed" ((PCon "PropResult" PWild PWild (PCon "PropPassedResult") PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "propResultPassed" (PWild) (EVar "False"))
(DTypeSig true "propResultDetail" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "propResultDetail" ((PCon "PropResult" PWild PWild PWild PWild (PVar "d") PWild PWild)) (EVar "d"))
(DTypeSig true "propResultStatus" (TyFun (TyCon "PropResult") (TyCon "PropStatus")))
(DFunDef false "propResultStatus" ((PCon "PropResult" PWild PWild (PVar "s") PWild PWild PWild PWild)) (EVar "s"))
(DTypeSig true "propResultFailureKind" (TyFun (TyCon "PropResult") (TyApp (TyCon "Option") (TyCon "PropFailureKind"))))
(DFunDef false "propResultFailureKind" ((PCon "PropResult" PWild PWild PWild (PVar "kind") PWild PWild PWild)) (EVar "kind"))
(DTypeSig true "propResultSeed" (TyFun (TyCon "PropResult") (TyCon "Int")))
(DFunDef false "propResultSeed" ((PCon "PropResult" PWild PWild PWild PWild PWild (PVar "seed") PWild)) (EVar "seed"))
(DTypeSig true "propResultCases" (TyFun (TyCon "PropResult") (TyCon "Int")))
(DFunDef false "propResultCases" ((PCon "PropResult" PWild PWild PWild PWild PWild PWild (PVar "cases"))) (EVar "cases"))
(DTypeSig true "runAllPropsResults" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runAllPropsResults" ((PVar "cases") (PVar "filterOpt") (PVar "propLines") (PVar "evalEnv") (PVar "program") (PVar "allDecls")) (EBlock (DoLet false false (PVar "props") (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "program")))) (DoLet false false (PVar "rootEnv") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EVar "evalEnv"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "props")) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EApp (EApp (EVar "buildGenEnv") (EVar "program")) (EVar "allDecls"))) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "props"))))))
(DTypeSig true "runAllPropRequestsResults" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runAllPropRequestsResults" ((PVar "requests") (PVar "propLines") (PVar "evalEnv") (PVar "program") (PVar "allDecls")) (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequests") (EVar "requests")) (EVar "propLines")) (EApp (EApp (EVar "buildGenEnv") (EVar "program")) (EVar "allDecls"))) (EVar "evalEnv")) (EApp (EVar "filterProps") (EVar "program"))))
(DTypeSig true "runAllPlannedPropRequestsResults" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runAllPlannedPropRequestsResults" ((PVar "root") (PVar "modules") (PVar "requests") (PVar "propLines") (PVar "evalEnv") (PVar "program")) (EMatch (EApp (EApp (EVar "buildPlanEnvModules") (EVar "root")) (EVar "modules")) (arm (PCon "Ok" (PVar "planEnv")) () (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequestsInEnv") (EVar "requests")) (EVar "propLines")) (EApp (EApp (EVar "buildGenEnvWithPlan") (EApp (EVar "runtimeModuleDecls") (EVar "modules"))) (EVar "planEnv"))) (EVar "evalEnv")) (EApp (EVar "filterProps") (EVar "program")))) (arm (PCon "Err" (PVar "err")) () (EApp (EApp (EMethodRef "map") (EApp (EVar "requestPlanError") (EVar "err"))) (EVar "requests")))))
(DTypeSig true "preparePlannedPropRequests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyTuple (TyCon "PlanEnv") (TyApp (TyCon "List") (TyCon "PreparedPropRequest")))))))))
(DFunDef false "preparePlannedPropRequests" ((PVar "root") (PVar "modules") (PVar "requests") (PVar "rootProps")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "env")) (ETuple (EVar "env") (EApp (EApp (EApp (EApp (EVar "prepareRequests") (EVar "env")) (EVar "requests")) (EVar "requests")) (EApp (EVar "filterProps") (EVar "rootProps")))))) (EApp (EApp (EVar "buildPlanEnvModules") (EVar "root")) (EVar "modules"))))
(DTypeSig false "prepareRequests" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "PreparedPropRequest")))))))
(DFunDef false "prepareRequests" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "prepareRequests" ((PVar "env") (PVar "all") (PCons (PAs "request" (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (PVar "rest")) (PVar "props")) (EBlock (DoLet false false (PVar "row") (EIf (EApp (EApp (EVar "requestNameRepeated") (EVar "name")) (EDictApp "all")) (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EVar "duplicateRequest") (EVar "name")) (EVar "seed")) (EVar "cases"))) (EIf (EBinOp "<=" (EVar "cases") (ELit (LInt 0))) (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "property request has a non-positive case count"))) (EVar "seed")) (EVar "cases"))) (EMatch (EApp (EApp (EVar "propsNamed") (EVar "name")) (EVar "props")) (arm (PList (PAs "decl" (PCon "DProp" PWild PWild (PVar "params") PWild))) () (EMatch (EApp (EApp (EApp (EVar "planPropParams") (EVar "env")) (EVar "name")) (EVar "params")) (arm (PCon "Ok" (PVar "plans")) () (EApp (EApp (EApp (EVar "PreparedRun") (EVar "request")) (EVar "decl")) (EVar "plans"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EApp (EVar "capabilityResult") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "e")))))) (arm (PList) () (EApp (EVar "PreparedResult") (EApp (EVar "missingRequest") (EVar "request")))) (arm PWild () (EApp (EVar "PreparedResult") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "property request is ambiguous: the root module declares '{name}' more than once"))) (EVar "seed")) (EVar "cases")))))))) (DoExpr (EBinOp "::" (EVar "row") (EApp (EApp (EApp (EApp (EVar "prepareRequests") (EVar "env")) (EDictApp "all")) (EVar "rest")) (EVar "props"))))))
(DTypeSig true "runPreparedPropRequestsResults" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runPreparedPropRequestsResults" ((PVar "planEnv") (PVar "helpers") (PVar "rows") (PVar "propLines") (PVar "evalEnv") (PVar "runtimeDecls")) (EApp (EApp (EApp (EApp (EVar "runPreparedRows") (EApp (EApp (EApp (EVar "buildGenEnvWithHelpers") (EVar "runtimeDecls")) (EVar "planEnv")) (EVar "helpers"))) (EVar "rows")) (EVar "propLines")) (EVar "evalEnv")))
(DTypeSig false "runPreparedRows" (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyCon "PreparedPropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult"))))))))
(DFunDef false "runPreparedRows" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "runPreparedRows" ((PVar "genEnv") (PCons (PCon "PreparedResult" (PVar "result")) (PVar "rest")) (PVar "propLines") (PVar "evalEnv")) (EBinOp "::" (EVar "result") (EApp (EApp (EApp (EApp (EVar "runPreparedRows") (EVar "genEnv")) (EVar "rest")) (EVar "propLines")) (EVar "evalEnv"))))
(DFunDef false "runPreparedRows" ((PVar "genEnv") (PCons (PCon "PreparedRun" (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases")) (PCon "DProp" PWild PWild (PVar "params") (PVar "body")) (PVar "plans")) (PVar "rest")) (PVar "propLines") (PVar "evalEnv")) (EBlock (DoLet false false PWild (EApp (EVar "seedPropRng") (EVar "seed"))) (DoExpr (EBinOp "::" (EMatch (EApp (EApp (EApp (EVar "helperFailure") (EVar "genEnv")) (EVar "evalEnv")) (EVar "plans")) (arm (PCon "Some" (PVar "detail")) () (EApp (EApp (EApp (EApp (EVar "runtimeResult") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "detail"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "beginCustomPropStream") (EVar "seed"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propResultOf") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "plans")) (EVar "cases")) (EVar "seed")) (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailurePlanned") (EVar "genEnv")) (EVar "evalEnv")) (EVar "params")) (EVar "plans")) (EVar "body")) (EVar "cases")) (ELit (LInt 1)))))))) (EApp (EApp (EApp (EApp (EVar "runPreparedRows") (EVar "genEnv")) (EVar "rest")) (EVar "propLines")) (EVar "evalEnv"))))))
(DFunDef false "runPreparedRows" ((PVar "genEnv") (PCons PWild (PVar "rest")) (PVar "propLines") (PVar "evalEnv")) (EApp (EApp (EApp (EApp (EVar "runPreparedRows") (EVar "genEnv")) (EVar "rest")) (EVar "propLines")) (EVar "evalEnv")))
(DTypeSig true "runAllPlannedPropRequestsWithHelpersResults" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyApp (TyCon "List") (TyCon "PropHelper")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult")))))))))))
(DFunDef false "runAllPlannedPropRequestsWithHelpersResults" ((PVar "root") (PVar "modules") (PVar "helpers") (PVar "requests") (PVar "propLines") (PVar "evalEnv") (PVar "program")) (EMatch (EApp (EApp (EVar "buildPlanEnvModules") (EVar "root")) (EVar "modules")) (arm (PCon "Ok" (PVar "planEnv")) () (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequestsInEnv") (EVar "requests")) (EVar "propLines")) (EApp (EApp (EApp (EVar "buildGenEnvWithHelpers") (EApp (EVar "runtimeModuleDecls") (EVar "modules"))) (EVar "planEnv")) (EVar "helpers"))) (EVar "evalEnv")) (EApp (EVar "filterProps") (EVar "program")))) (arm (PCon "Err" (PVar "err")) () (EApp (EApp (EMethodRef "map") (EApp (EVar "requestPlanError") (EVar "err"))) (EVar "requests")))))
(DTypeSig false "runtimeModuleDecls" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "runtimeModuleDecls" ((PList)) (EListLit))
(DFunDef false "runtimeModuleDecls" ((PCons (PCon "PlanModule" PWild PWild (PVar "runtime")) (PVar "rest"))) (EBinOp "++" (EVar "runtime") (EApp (EVar "runtimeModuleDecls") (EVar "rest"))))
(DTypeSig false "requestPlanError" (TyFun (TyCon "PlanError") (TyFun (TyCon "PropRequest") (TyCon "PropResult"))))
(DFunDef false "requestPlanError" ((PVar "err") (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (EApp (EApp (EApp (EApp (EVar "capabilityResult") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "err")))
(DTypeSig false "runPropRequests" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runPropRequests" ((PVar "requests") (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PVar "props")) (EBlock (DoLet false false (PVar "rootEnv") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EVar "evalEnv"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequestsChecked") (EVar "requests")) (EVar "requests")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "props")))))
(DTypeSig false "runPropRequestsInEnv" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runPropRequestsInEnv" ((PVar "requests") (PVar "propLines") (PVar "genEnv") (PVar "rootEnv") (PVar "props")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequestsChecked") (EVar "requests")) (EVar "requests")) (EVar "propLines")) (EVar "genEnv")) (EListLit)) (EVar "rootEnv")) (EVar "props")))
(DTypeSig false "runPropRequestsChecked" (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult")))))))))))
(DFunDef false "runPropRequestsChecked" (PWild (PList) PWild PWild PWild PWild PWild) (EListLit))
(DFunDef false "runPropRequestsChecked" ((PVar "all") (PCons (PAs "request" (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (PVar "rest")) (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PVar "rootEnv") (PVar "props")) (EBlock (DoLet false false (PVar "result") (EIf (EApp (EApp (EVar "requestNameRepeated") (EVar "name")) (EDictApp "all")) (EApp (EApp (EApp (EVar "duplicateRequest") (EVar "name")) (EVar "seed")) (EVar "cases")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequest") (EVar "request")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "props")))) (DoExpr (EBinOp "::" (EVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runPropRequestsChecked") (EDictApp "all")) (EVar "rest")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "props"))))))
(DTypeSig false "requestNameRepeated" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyCon "Bool"))))
(DFunDef false "requestNameRepeated" ((PVar "name") (PVar "requests")) (EBinOp ">" (EApp (EApp (EVar "requestNameCount") (EVar "name")) (EVar "requests")) (ELit (LInt 1))))
(DTypeSig false "requestNameCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropRequest")) (TyCon "Int"))))
(DFunDef false "requestNameCount" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "requestNameCount" ((PVar "name") (PCons (PCon "PropRequest" (PVar "actual") PWild PWild) (PVar "rest"))) (EBinOp "+" (EIf (EBinOp "==" (EVar "name") (EVar "actual")) (ELit (LInt 1)) (ELit (LInt 0))) (EApp (EApp (EVar "requestNameCount") (EVar "name")) (EVar "rest"))))
(DTypeSig false "duplicateRequest" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "PropResult")))))
(DFunDef false "duplicateRequest" ((PVar "name") (PVar "seed") (PVar "cases")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "property request names '{name}' more than once"))) (EVar "seed")) (EVar "cases")))
(DTypeSig false "runPropRequest" (TyFun (TyCon "PropRequest") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyCon "PropResult")))))))))
(DFunDef false "runPropRequest" ((PAs "request" (PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PVar "rootEnv") (PVar "props")) (EBlock (DoLet false false (PVar "matches") (EApp (EApp (EVar "propsNamed") (EVar "name")) (EVar "props"))) (DoExpr (EIf (EBinOp "<=" (EVar "cases") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (ELit (LString "property request has a non-positive case count"))) (EVar "seed")) (EVar "cases")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "matches")) (ELit (LInt 1))) (EBlock (DoLet false false PWild (EApp (EVar "seedPropRng") (EVar "seed"))) (DoExpr (EMatch (EVar "matches") (arm (PList (PCon "DProp" PWild PWild (PVar "params") (PVar "body"))) () (EMatch (EApp (EApp (EApp (EVar "planPropParams") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "name")) (EVar "params")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "capabilityResult") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "e"))) (arm (PCon "Ok" (PVar "plans")) () (EMatch (EApp (EApp (EApp (EVar "helperFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "plans")) (arm (PCon "Some" (PVar "detail")) () (EApp (EApp (EApp (EApp (EVar "runtimeResult") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "detail"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "beginCustomPropStream") (EVar "seed"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propResultOf") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "plans")) (EVar "cases")) (EVar "seed")) (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "params")) (EVar "body")) (EVar "cases")) (ELit (LInt 1))))))))))) (arm PWild () (EApp (EVar "missingRequest") (EVar "request")))))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "matches")) (ELit (LInt 0))) (EApp (EVar "missingRequest") (EVar "request")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EBinOp "++" (EBinOp "++" (ELit (LString "property request is ambiguous: the root module declares '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' more than once")))) (EVar "seed")) (EVar "cases"))))))))
(DTypeSig false "propsNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "propsNamed" (PWild (PList)) (EListLit))
(DFunDef false "propsNamed" ((PVar "wanted") (PCons (PAs "d" (PCon "DProp" PWild (PVar "name") PWild PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EVar "wanted") (EVar "name")) (EBinOp "::" (EVar "d") (EApp (EApp (EVar "propsNamed") (EVar "wanted")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "propsNamed") (EVar "wanted")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "propsNamed" ((PVar "wanted") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "propsNamed") (EVar "wanted")) (EVar "rest")))
(DTypeSig false "missingRequest" (TyFun (TyCon "PropRequest") (TyCon "PropResult")))
(DFunDef false "missingRequest" ((PCon "PropRequest" (PVar "name") (PVar "seed") (PVar "cases"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropProtocolError"))) (EBinOp "++" (EBinOp "++" (ELit (LString "property request names no root declaration '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "'")))) (EVar "seed")) (EVar "cases")))
(DTypeSig false "runEachResult" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "GenEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "PropResult"))))))))))
(DFunDef false "runEachResult" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "runEachResult" ((PVar "cases") (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PVar "rootEnv") (PCons (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "seedAtStart") (EUnOp "!" (EVar "propRngStateRef"))) (DoExpr (EBinOp "::" (EMatch (EApp (EApp (EApp (EVar "planPropParams") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "name")) (EVar "params")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EApp (EVar "capabilityResult") (EVar "name")) (EVar "seedAtStart")) (EVar "cases")) (EVar "e"))) (arm (PCon "Ok" (PVar "plans")) () (EMatch (EApp (EApp (EApp (EVar "helperFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "plans")) (arm (PCon "Some" (PVar "detail")) () (EApp (EApp (EApp (EApp (EVar "runtimeResult") (EVar "name")) (EVar "seedAtStart")) (EVar "cases")) (EVar "detail"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "beginCustomPropStream") (EVar "seedAtStart"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "propResultOf") (EApp (EVar "genEnvPlan") (EVar "genEnv"))) (EVar "plans")) (EVar "cases")) (EVar "seedAtStart")) (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "genEnv")) (EVar "rootEnv")) (EVar "params")) (EVar "body")) (EVar "cases")) (ELit (LInt 1)))))))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "rest"))))))
(DFunDef false "runEachResult" ((PVar "cases") (PVar "propLines") (PVar "genEnv") (PVar "evalEnv") (PVar "rootEnv") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EVar "genEnv")) (EVar "evalEnv")) (EVar "rootEnv")) (EVar "rest")))
(DTypeSig false "planPropParams" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "GenPlan")))))))
(DFunDef false "planPropParams" (PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "planPropParams" ((PVar "planEnv") (PVar "propName") (PCons (PCon "PropParam" (PVar "param") PWild (PVar "ty")) (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planFor") (EVar "planEnv")) (EVar "propName")) (EVar "param")) (EVar "ty")) (EApp (EApp (EApp (EVar "planPropParams") (EVar "planEnv")) (EVar "propName")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "plan")) (PCon "Ok" (PVar "plans"))) () (EApp (EVar "Ok") (EBinOp "::" (EVar "plan") (EVar "plans")))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "capabilityResult" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "PlanError") (TyCon "PropResult"))))))
(DFunDef false "capabilityResult" ((PVar "name") (PVar "seed") (PVar "cases") (PVar "err")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropCapabilityError"))) (EApp (EVar "planErrorText") (EVar "err"))) (EVar "seed")) (EVar "cases")))
(DTypeSig false "runtimeResult" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "PropResult"))))))
(DFunDef false "runtimeResult" ((PVar "name") (PVar "seed") (PVar "cases") (PVar "detail")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropErroredResult")) (EApp (EVar "Some") (EVar "PropRuntimeError"))) (EVar "detail")) (EVar "seed")) (EVar "cases")))
(DTypeSig false "propResultOf" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "PropResult")))))))))
(DFunDef false "propResultOf" (PWild PWild (PVar "cases") (PVar "seed") (PVar "_line") (PVar "name") (PCon "PropPassed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropPassedResult")) (EVar "None")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "cases")))) (ELit (LString " tests passed")))) (EVar "seed")) (EVar "cases")))
(DFunDef false "propResultOf" ((PVar "planEnv") (PVar "plans") (PVar "cases") (PVar "seed") (PVar "line") (PVar "name") (PCon "PropFailed" (PVar "run") (PVar "shrunk") (PVar "fuelExhausted"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PropResult") (ELit (LString "eval"))) (EVar "name")) (EVar "PropFailedResult")) (EApp (EVar "Some") (EVar "PropLawFalse"))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "lineDetailPrefix") (EVar "line")) (ELit (LString "failed after ")) (EApp (EVar "intToString") (EVar "run")) (EIf (EBinOp "==" (EVar "run") (ELit (LInt 1))) (ELit (LString " test; counterexample: ")) (ELit (LString " tests; counterexample: "))) (EApp (EApp (EApp (EVar "renderCounterexample") (EVar "planEnv")) (EVar "plans")) (EVar "shrunk")) (EIf (EVar "fuelExhausted") (ELit (LString " (WARNING: shrink fuel exhausted, counterexample may not be minimal — see #1307)")) (ELit (LString "")))))) (EVar "seed")) (EVar "cases")))
(DTypeSig false "lineDetailPrefix" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "lineDetailPrefix" ((PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "lineDetailPrefix" ((PVar "line")) (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))))
(DTypeSig false "renderCounterexample" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "String")))))
(DFunDef false "renderCounterexample" (PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "renderCounterexample" ((PVar "env") (PCons (PVar "plan") (PVar "plans")) (PList (PTuple (PVar "name") (PVar "value")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value")))) (ELit (LString ""))))
(DFunDef false "renderCounterexample" ((PVar "env") (PCons (PVar "plan") (PVar "plans")) (PCons (PTuple (PVar "name") (PVar "value")) (PVar "rest"))) (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString " = ")) (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value")) (ELit (LString ", ")) (EApp (EApp (EApp (EVar "renderCounterexample") (EVar "env")) (EVar "plans")) (EVar "rest")))))
(DFunDef false "renderCounterexample" (PWild PWild (PList (PTuple (PVar "name") PWild))) (EBinOp "++" (EVar "name") (ELit (LString " = <unplanned>"))))
(DFunDef false "renderCounterexample" ((PVar "env") (PList) (PCons (PTuple (PVar "name") PWild) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " = <unplanned>, "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "renderCounterexample") (EVar "env")) (EListLit)) (EVar "rest")))) (ELit (LString ""))))
(DTypeSig false "renderPlanValue" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String")))))
(DFunDef false "renderPlanValue" (PWild (PCon "GInt") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" (PWild (PCon "GBool") (PCon "VBool" (PCon "True"))) (ELit (LString "True")))
(DFunDef false "renderPlanValue" (PWild (PCon "GBool") (PCon "VBool" (PCon "False"))) (ELit (LString "False")))
(DFunDef false "renderPlanValue" (PWild (PCon "GBool") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" (PWild (PCon "GFloat") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" (PWild (PCon "GChar") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" (PWild (PCon "GString") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" (PWild (PCon "GUnit") (PVar "value")) (EApp (EVar "ppValue") (EVar "value")))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GList" (PVar "plan")) (PCon "VList" (PVar "values"))) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EApp (EApp (EVar "renderPlanValues") (EVar "env")) (EVar "plan")) (EVar "values"))) (ELit (LString "]"))))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GArray" (PVar "plan")) (PCon "VArray" (PVar "values"))) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EApp (EApp (EVar "renderPlanValues") (EVar "env")) (EVar "plan")) (EApp (EVar "arrayValues") (EVar "values")))) (ELit (LString "]"))))
(DFunDef false "renderPlanValue" (PWild (PCon "GOption" PWild) (PCon "VCon" (PLit (LString "None")) (PList))) (ELit (LString "None")))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GOption" (PVar "plan")) (PCon "VCon" (PLit (LString "Some")) (PList (PVar "value")))) (EBinOp "++" (EBinOp "++" (ELit (LString "Some(")) (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value"))) (ELit (LString ")"))))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GResult" (PVar "err") PWild) (PCon "VCon" (PLit (LString "Err")) (PList (PVar "value")))) (EBinOp "++" (EBinOp "++" (ELit (LString "Err(")) (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "err")) (EVar "value"))) (ELit (LString ")"))))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GResult" PWild (PVar "ok")) (PCon "VCon" (PLit (LString "Ok")) (PList (PVar "value")))) (EBinOp "++" (EBinOp "++" (ELit (LString "Ok(")) (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "ok")) (EVar "value"))) (ELit (LString ")"))))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GTuple" (PVar "plans")) (PCon "VTuple" (PVar "values"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EApp (EVar "renderPlanValuePairs") (EVar "env")) (EVar "plans")) (EVar "values"))) (ELit (LString ")"))))
(DFunDef false "renderPlanValue" ((PVar "env") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild)) (PVar "value")) (EApp (EApp (EApp (EApp (EVar "renderNominalValue") (EVar "env")) (EVar "nominal")) (EVar "key")) (EVar "value")))
(DFunDef false "renderPlanValue" ((PVar "env") (PCon "GCustom" (PCon "CustomPlan" (PVar "key") (PVar "carrier") PWild)) (PVar "value")) (EMatch (EApp (EApp (EVar "displayCarrierPlans") (EVar "env")) (EApp (EVar "carrierArgs") (EVar "carrier"))) (arm (PCon "Some" (PVar "args")) () (EApp (EApp (EApp (EApp (EVar "renderNominalValue") (EVar "env")) (EApp (EApp (EVar "GNominal") (EVar "key")) (EVar "args"))) (EVar "key")) (EVar "value"))) (arm (PCon "None") () (EApp (EVar "hiddenType") (EVar "key")))))
(DFunDef false "renderPlanValue" (PWild PWild PWild) (ELit (LString "<value>")))
(DTypeSig false "renderPlanValues" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "String")))))
(DFunDef false "renderPlanValues" (PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "renderPlanValues" ((PVar "env") (PVar "plan") (PList (PVar "value"))) (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value")))
(DFunDef false "renderPlanValues" ((PVar "env") (PVar "plan") (PCons (PVar "value") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "renderPlanValues") (EVar "env")) (EVar "plan")) (EVar "rest")))) (ELit (LString ""))))
(DTypeSig false "arrayValues" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "arrayValues" ((PVar "values")) (EApp (EApp (EApp (EVar "arrayValuesGo") (EVar "values")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "values"))))
(DTypeSig false "arrayValuesGo" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "arrayValuesGo" (PWild (PVar "index") (PVar "size")) (EIf (EBinOp ">=" (EMethodRef "index") (EVar "size")) (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "arrayValuesGo" ((PVar "values") (PVar "index") (PVar "size")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EMethodRef "index")) (EVar "values")) (EApp (EApp (EApp (EVar "arrayValuesGo") (EVar "values")) (EBinOp "+" (EMethodRef "index") (ELit (LInt 1)))) (EVar "size"))))
(DTypeSig false "renderPlanValuePairs" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "String")))))
(DFunDef false "renderPlanValuePairs" (PWild (PList) (PList)) (ELit (LString "")))
(DFunDef false "renderPlanValuePairs" ((PVar "env") (PCons (PVar "plan") (PVar "plans")) (PCons (PVar "value") (PVar "values"))) (EBlock (DoLet false false (PVar "rendered") (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "plans")) (EApp (EVar "isEmptyL") (EVar "values"))) (EVar "rendered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "rendered"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "renderPlanValuePairs") (EVar "env")) (EVar "plans")) (EVar "values")))) (ELit (LString "")))))))
(DFunDef false "renderPlanValuePairs" (PWild PWild PWild) (ELit (LString "<value>")))
(DTypeSig false "renderNominalValue" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String"))))))
(DFunDef false "renderNominalValue" ((PVar "env") (PVar "nominal") (PVar "key") (PVar "value")) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild (PVar "owner") PWild (PVar "visibility") (PVar "ctors"))) () (EIf (EApp (EApp (EApp (EVar "nominalVisible") (EVar "env")) (EVar "owner")) (EVar "visibility")) (EApp (EApp (EApp (EApp (EApp (EVar "renderVisibleNominal") (EVar "env")) (EVar "nominal")) (EVar "key")) (EVar "ctors")) (EVar "value")) (EApp (EVar "hiddenType") (EVar "key")))) (arm (PCon "Err" PWild) () (EApp (EVar "hiddenType") (EVar "key")))))
(DTypeSig false "nominalVisible" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "PlanVisibility") (TyCon "Bool")))))
(DFunDef false "nominalVisible" (PWild PWild (PCon "PlanPublicCtors")) (EVar "True"))
(DFunDef false "nominalVisible" ((PCon "PlanEnv" (PVar "root") PWild PWild PWild PWild) (PVar "owner") (PCon "PlanLocal")) (EBinOp "==" (EVar "owner") (EVar "root")))
(DFunDef false "nominalVisible" ((PCon "PlanEnv" (PVar "root") PWild PWild PWild PWild) (PVar "owner") (PCon "PlanAbstract")) (EBinOp "==" (EVar "owner") (EVar "root")))
(DTypeSig false "hiddenType" (TyFun (TyCon "TypeKey") (TyCon "String")))
(DFunDef false "hiddenType" ((PCon "TypeKey" (PVar "name") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EVar "name")) (ELit (LString ">"))))
(DTypeSig false "renderVisibleNominal" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String")))))))
(DFunDef false "renderVisibleNominal" ((PVar "env") (PVar "nominal") (PVar "key") (PVar "ctors") (PCon "VCon" (PVar "runtime") (PVar "values"))) (EMatch (EApp (EApp (EVar "runtimeCtor") (EVar "runtime")) (EVar "ctors")) (arm (PCon "Some" (PVar "ctor")) () (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "renderPositionalCtor") (EVar "env")) (EVar "ctor")) (EVar "fields")) (EVar "values"))) (arm (PCon "Err" PWild) () (EApp (EVar "hiddenType") (EVar "key"))))) (arm (PCon "None") () (EApp (EVar "hiddenType") (EVar "key")))))
(DFunDef false "renderVisibleNominal" ((PVar "env") (PVar "nominal") (PVar "key") (PVar "ctors") (PCon "VRecord" (PVar "runtime") (PVar "values"))) (EMatch (EApp (EApp (EVar "runtimeCtor") (EVar "runtime")) (EVar "ctors")) (arm (PCon "Some" (PVar "ctor")) () (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "renderNamedCtor") (EVar "env")) (EVar "ctor")) (EVar "fields")) (EVar "values"))) (arm (PCon "Err" PWild) () (EApp (EVar "hiddenType") (EVar "key"))))) (arm (PCon "None") () (EApp (EVar "hiddenType") (EVar "key")))))
(DFunDef false "renderVisibleNominal" (PWild PWild (PVar "key") PWild PWild) (EApp (EVar "hiddenType") (EVar "key")))
(DTypeSig false "runtimeCtor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyApp (TyCon "Option") (TyCon "PlanCtor")))))
(DFunDef false "runtimeCtor" (PWild (PList)) (EVar "None"))
(DFunDef false "runtimeCtor" ((PVar "runtime") (PCons (PAs "ctor" (PCon "PlanCtor" PWild (PVar "actual") PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EVar "runtime") (EVar "actual")) (EApp (EVar "Some") (EVar "ctor")) (EIf (EVar "otherwise") (EApp (EApp (EVar "runtimeCtor") (EVar "runtime")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "renderPositionalCtor" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "PlanCtor") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "String"))))))
(DFunDef false "renderPositionalCtor" ((PVar "env") (PCon "PlanCtor" (PVar "source") PWild PWild) (PVar "fields") (PVar "values")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "source"))) (ELit (LString "("))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "renderFields") (EVar "env")) (EVar "fields")) (EVar "values")))) (ELit (LString ")"))))
(DTypeSig false "renderNamedCtor" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "PlanCtor") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "String"))))))
(DFunDef false "renderNamedCtor" ((PVar "env") (PCon "PlanCtor" (PVar "source") PWild PWild) (PVar "fields") (PVar "values")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "source"))) (ELit (LString " { "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "renderNamedFields") (EVar "env")) (EVar "fields")) (EVar "values")))) (ELit (LString " }"))))
(DTypeSig false "renderFields" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "String")))))
(DFunDef false "renderFields" (PWild (PList) (PList)) (ELit (LString "")))
(DFunDef false "renderFields" ((PVar "env") (PCons (PTuple PWild (PVar "plan")) (PVar "plans")) (PCons (PVar "value") (PVar "values"))) (EBlock (DoLet false false (PVar "rendered") (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "plans")) (EApp (EVar "isEmptyL") (EVar "values"))) (EVar "rendered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "rendered"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "renderFields") (EVar "env")) (EVar "plans")) (EVar "values")))) (ELit (LString "")))))))
(DFunDef false "renderFields" (PWild PWild PWild) (ELit (LString "<value>")))
(DTypeSig false "renderNamedFields" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "String")))))
(DFunDef false "renderNamedFields" (PWild (PList) PWild) (ELit (LString "")))
(DFunDef false "renderNamedFields" ((PVar "env") (PCons (PTuple (PCon "Some" (PVar "name")) (PVar "plan")) (PVar "rest")) (PVar "values")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "values")) (arm (PCon "Some" (PVar "value")) () (EBlock (DoLet false false (PVar "rendered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "renderPlanValue") (EVar "env")) (EVar "plan")) (EVar "value")))) (ELit (LString "")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rest")) (EVar "rendered") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "rendered"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "renderNamedFields") (EVar "env")) (EVar "rest")) (EVar "values")))) (ELit (LString ""))))))) (arm (PCon "None") () (EBinOp "++" (EVar "name") (ELit (LString " = <value>"))))))
(DFunDef false "renderNamedFields" (PWild (PCons (PTuple (PCon "None") PWild) PWild) PWild) (ELit (LString "<value>")))
(DTypeSig false "carrierArgs" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "carrierArgs" ((PVar "carrier")) (EApp (EApp (EVar "carrierArgsGo") (EListLit)) (EVar "carrier")))
(DTypeSig false "carrierArgsGo" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "carrierArgsGo" ((PVar "acc") (PCon "TyApp" (PVar "head") (PVar "arg"))) (EApp (EApp (EVar "carrierArgsGo") (EBinOp "::" (EVar "arg") (EVar "acc"))) (EVar "head")))
(DFunDef false "carrierArgsGo" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "displayCarrierPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "GenPlan"))))))
(DFunDef false "displayCarrierPlans" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "displayCarrierPlans" ((PVar "env") (PCons (PVar "ty") (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planFor") (EVar "env")) (ELit (LString ""))) (ELit (LString "display"))) (EVar "ty")) (EApp (EApp (EVar "displayCarrierPlans") (EVar "env")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "plan")) (PCon "Some" (PVar "plans"))) () (EApp (EVar "Some") (EBinOp "::" (EVar "plan") (EVar "plans")))) (arm PWild () (EVar "None"))))
(DTypeSig true "hasProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasProps" ((PVar "decls")) (EApp (EApp (EVar "anyDecl") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "anyDecl" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "anyDecl" (PWild (PList)) (EVar "False"))
(DFunDef false "anyDecl" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "p") (EVar "d")) (EApp (EApp (EVar "anyDecl") (EVar "p")) (EVar "rest"))))
