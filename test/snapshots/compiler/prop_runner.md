# META
source_lines=930
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
-- The RNG lives in eval.mdk's externs (`randomInt`/…), a self-contained LCG
-- (NOT the reference's SplitMix64 nor OCaml's `Random`); a PASSING prop's output
-- (`OK (100 tests)`) is RNG-independent, so it matches `medaka test`.  A FAILING
-- prop's shrunk counterexample is RNG-dependent and diverges across all three
-- runners — see the report in test/diff_compiler_test.sh.

import frontend.ast.{
  Decl,
  Expr,
  DProp,
  DData,
  DNewtype,
  PropParam,
  Ty(..),
  Variant(..),
  Field(..),
  ConPayload(..),
}
import eval.eval.{Value(..), EvalEnv(..), eval, extendEnv, force, ppValue}
import support.util.{listLen, lookupAssoc, reverseL, isEmptyL, filterList, zipL}

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

-- `--seed <n>`: reseed the prop runner's own RNG before running. Never touches
-- `rngStateRef`.
export
seedPropRng : Int -> Unit
seedPropRng n = propRngStateRef := n

rngNextLocal : Unit -> Int
-- Intentional cross-file duplicate of the same helper in eval.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
rngNextLocal _ =
  let s = (!propRngStateRef * 1103515245 + 12345) % 2147483648
  propRngStateRef := s
  s

randIntRange : Int -> Int -> Int
randIntRange lo hi =
  let range = hi - lo + 1
  if range <= 0 then lo else lo + rngNextLocal () % range

randBoolL : Unit -> Bool
randBoolL _ = rngNextLocal () % 2 == 1

-- ── tydef registry (built from the program's data/record decls) ─────────────

public export data TyDef = TDData (List String) (List Variant)

buildTyDefs : List Decl -> List (String, TyDef)
buildTyDefs [] = []
buildTyDefs (d :: rest) = match d
  DData { dataName = name, dataParams = params, dataCtors = variants } =>
    (name, TDData params variants) :: buildTyDefs rest
  DNewtype { newtypeName = name, newtypeParams = params, newtypeCtor = con, newtypeFieldTy = fty } =>
    (name, TDData params [Variant con (ConPos [fty])]) :: buildTyDefs rest
  _ => buildTyDefs rest

-- ── type substitution + spine peeling ─────────────────────────────────────

substTy : List (String, Ty) -> Ty -> Ty
substTy subst (TyVar v) = match lookupAssoc v subst
  Some t => t
  None => TyVar v
substTy subst (TyApp a b) = TyApp (substTy subst a) (substTy subst b)
substTy subst (TyTuple ts) = TyTuple (map (substTy subst) ts)
substTy subst (TyFun a b) = TyFun (substTy subst a) (substTy subst b)
substTy _ t = t

-- Peel a TyApp spine: `Pair a b` → Some ("Pair", [a, b]); `Int` → Some ("Int", []).
tySpine : Ty -> Option (String, List Ty)
tySpine t = tySpineGo [] t

tySpineGo : List Ty -> Ty -> Option (String, List Ty)
tySpineGo acc (TyApp f a) = tySpineGo (a :: acc) f
tySpineGo acc (TyCon { tyConName = n }) = Some (n, acc)
tySpineGo _ _ = None

-- ── value generation ─────────────────────────────────────────────────────────

-- `depth` is the USER-ADT NESTING depth of the value being generated: it is
-- incremented only when descending into a user constructor's payload
-- (`genVariant`), never by `List`/`Array`/tuple/`Option`/`Result`.  Two arms
-- read it: `genUser`'s constructor choice (`pickVariant`) and the `List`/
-- `Array` LENGTH draw (`listLenBound`).  Every other arm ignores it, and both
-- readers take a fast path that reproduces the pre-#2294 draw exactly whenever
-- no recursion is in play, so the draw sequence for a type with no user ADT in
-- it is unchanged.
genForType : List (String, TyDef) ->
  List (String, Ty) ->
  Int ->
  Ty ->
  <e> Value e
genForType tydefs subst depth (TyVar v) = match lookupAssoc v subst
  Some t => genForType tydefs subst depth t
  None =>
    panic
      ("prop_runner: cannot generate values for unbound type variable '"
        ++ v
        ++ "'")
genForType tydefs subst depth (TyCon { tyConName = "Int" }) =
  VInt (randIntRange (-1000) 1000)
genForType tydefs subst depth (TyCon { tyConName = "Bool" }) =
  VBool (randBoolL ())
genForType tydefs subst depth (TyCon { tyConName = "Float" }) = genFloat ()
genForType tydefs subst depth (TyCon { tyConName = "Char" }) =
  VChar (genCharStr ())
genForType tydefs subst depth (TyCon { tyConName = "String" }) =
  VString (genString ())
genForType tydefs subst depth (TyCon { tyConName = "Unit" }) = VUnit
genForType tydefs subst depth (TyApp (TyCon { tyConName = "List" }) t) =
  VList
    (genList
      tydefs
      subst
      depth
      t
      (randIntRange 0 (listLenBound tydefs depth t)))
genForType tydefs subst depth (TyApp (TyCon { tyConName = "Array" }) t) =
  VArray
    (arrayFromList
      (genList
        tydefs
        subst
        depth
        t
        (randIntRange 0 (listLenBound tydefs depth t))))
genForType tydefs subst depth (TyApp (TyCon { tyConName = "Option" }) t) =
  if randBoolL () then
    VCon "None" []
  else
    VCon "Some" [genForType tydefs subst depth t]
genForType tydefs subst depth (TyApp (TyApp (TyCon { tyConName = "Result" }) e) a) =
  if randBoolL () then
    VCon "Ok" [genForType tydefs subst depth a]
  else
    VCon "Err" [genForType tydefs subst depth e]
genForType tydefs subst depth (TyTuple ts) =
  VTuple (genTuple tydefs subst depth ts)
genForType tydefs subst depth ty = genUserOrFail tydefs subst depth ty

genTuple : List (String, TyDef) ->
  List (String, Ty) ->
  Int ->
  List Ty ->
  <e> List (Value e)
genTuple _ _ _ [] = []
genTuple tydefs subst depth (t :: rest) =
  genForType tydefs subst depth t :: genTuple tydefs subst depth rest

genList : List (String, TyDef) ->
  List (String, Ty) ->
  Int ->
  Ty ->
  Int ->
  <e> List (Value e)
genList _ _ _ _ 0 = []
genList tydefs subst depth t n =
  genForType tydefs subst depth t :: genList tydefs subst depth t (n - 1)

genFloat : Unit -> <e> Value e
genFloat _ =
  let r = rngNextLocal () % 2000001
  VFloat (intToFloat r * (1.0 / 1000000.0) - 1.0)

genCharStr : Unit -> String
genCharStr _ = charToStr (charFromCodeU (32 + rngNextLocal () % 95))

charFromCodeU : Int -> Char
-- Intentional cross-file duplicate of the same helper in eval.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
charFromCodeU n = match charFromCode n
  Some c => c
  None => ' '

-- random String of printable ASCII, length 0..10
genString : Unit -> String
genString _ = stringConcat (genStringGo (randIntRange 0 10))

genStringGo : Int -> List String
genStringGo 0 = []
genStringGo n = genCharStr () :: genStringGo (n - 1)

genUserOrFail : List (String, TyDef) ->
  List (String, Ty) ->
  Int ->
  Ty ->
  <e> Value e
genUserOrFail tydefs subst depth ty = match tySpine ty
  Some (name, args) => match lookupAssoc name tydefs
    Some tydef => genUser tydefs subst depth name tydef args
    None =>
      panic
        ("prop_runner: no generator for type '"
          ++ name
          ++ "'. Define an explicit generator (there is no 'Arbitrary' deriver).")
  None => panic "prop_runner: cannot generate values for type"

genUser : List (String, TyDef) ->
  List (String, Ty) ->
  Int ->
  String ->
  TyDef ->
  List Ty ->
  <e> Value e
genUser tydefs subst depth name tydef args =
  let args2 = map (substTy subst) args
  match tydef
    TDData params variants =>
      let subst2 =
        if listLen params == listLen args2 then zipL params args2 else []
      let v = pickVariant tydefs name depth variants
      genVariant tydefs subst2 depth v

genVariant : List (String, TyDef) ->
  List (String, Ty) ->
  Int ->
  Variant ->
  <e> Value e
genVariant tydefs subst depth (Variant cname payload) = match payload
  ConPos tys => VCon cname (map (genForType tydefs subst (depth + 1)) tys)
  ConNamed fields _ =>
    VRecord cname (map (genField tydefs subst (depth + 1)) fields)

genField : List (String, TyDef) ->
  List (String, Ty) ->
  Int ->
  Field ->
  <e> (String, Value e)
genField tydefs subst depth (Field fname fty) =
  (fname, genForType tydefs subst depth fty)

-- ── size-aware constructor choice (#2294) ───────────────────────────────────
-- Before this, `genUser` picked a constructor uniformly at random with no size
-- parameter.  For any ADT whose expected count of self-referential fields per
-- uniformly-chosen constructor exceeds 1 — `data T = Leaf | Node T T T`, mean
-- (0 + 3)/2 = 1.5 — that is a SUPERCRITICAL branching process: generation
-- diverges with positive probability on every draw, and the runner dies with
-- `E-STACK-OVERFLOW` rather than reporting anything.  (`End | One R | Two R R`
-- is mean 1.0 — critical: finite almost surely but with infinite expected
-- size, so it degrades rather than aborts.)
--
-- The fix biases the choice toward constructors that cannot recurse, more
-- strongly the deeper we already are, which drives the process subcritical
-- (mean < 1) and so back to finite expected size:
--
--   weight(v, depth) = if v can recurse then max 1 (recWeight0 - depth)
--                      else recWeight0
--
-- 🚨 At depth 0 — and at ANY depth for an ADT none of whose constructors can
-- reach the ADT ITSELF — every weight is `recWeight0`, i.e. the choice is
-- still UNIFORM.  That is the property that keeps this from silently narrowing
-- the value space every existing prop samples: such an ADT takes the
-- `allEqualInts` fast path below and draws the SAME `randIntRange 0 (n - 1)`
-- it always did, so its value stream is byte-identical.  Only a genuinely
-- recursive ADT, at depth ≥ 1, sees a different distribution — and it still
-- reaches every shape it used to at the shallow depths, just not depth 1000.
--
-- ⚠️ "Can reach the ADT itself" is a REACHABILITY question over the type
-- graph, not a one-hop "mentions some user ADT" question.  The first cut of
-- this fix asked the latter, which flagged `F1` in
--
--   data Leaf = L0 | L1 ; data Fin = F0 | F1 Leaf
--
-- as recursive purely because `Leaf` is user-declared, even though `Leaf` can
-- never lead back to `Fin`.  Nested inside five non-recursive wrappers that
-- put `Fin` at depth 5, it drove P(F1) from the correct 0.5 down to 1/7 —
-- exactly the silent distribution narrowing this comment claims not to
-- happen.  `variantRecursive` therefore takes the OWNING ADT's name and asks
-- `adtReaches`, which walks the whole mention graph.
recWeight0 : Int
recWeight0 = 6

-- Hard floor under the soft weighting: past this much user-ADT nesting, drop
-- recursive constructors entirely IF a non-recursive one exists.  Deliberately
-- far beyond anything the weighting above realistically reaches (at depth ≥ 5
-- a `Node T T T` is picked with probability 1/7, so the expected child count
-- is 3/7 < 1 and the tail decays geometrically) — it exists so the bound is a
-- guarantee rather than a probability, not to shape the distribution.
maxGenDepth : Int
maxGenDepth = 24

-- ── recursion detection: reachability over the ADT mention graph ────────────
-- Edges: ADT `X` → ADT `Y` whenever some constructor of `X` has a payload type
-- mentioning `Y`.  `adtReaches tydefs seen src target` is "src IS target, or
-- src reaches target along ≥ 1 edge"; `adtStepReaches` is the strict ≥ 1 edge
-- form (used for the on-a-cycle test).  `seen` is the DFS visited set, so a
-- cyclic graph terminates.
--
-- `TyVar` is treated as mentioning nothing rather than resolved through
-- `subst`: a parameter bound to its own name (`Tree a` generated with `a`
-- free) would make resolution loop, and a recursive occurrence always shows up
-- as the ADT's own `TyCon` head anyway.
memberStr : String -> List String -> Bool
memberStr _ [] = False
memberStr x (y :: rest) = x == y || memberStr x rest

adtReaches : List (String, TyDef) -> List String -> String -> String -> Bool
adtReaches tydefs seen src target =
  src == target || adtStepReaches tydefs seen src target

adtStepReaches : List (String, TyDef) -> List String -> String -> String -> Bool
adtStepReaches tydefs seen src target =
  if memberStr src seen then
    False
  else match lookupAssoc src tydefs
    None => False
    Some (TDData _ variants) =>
      anyVariantReaches tydefs (src :: seen) variants target

anyVariantReaches : List (String, TyDef) ->
  List String ->
  List Variant ->
  String ->
  Bool
anyVariantReaches _ _ [] _ = False
anyVariantReaches tydefs seen (v :: rest) target =
  variantReaches tydefs seen v target
    || anyVariantReaches tydefs seen rest target

variantReaches : List (String, TyDef) ->
  List String ->
  Variant ->
  String ->
  Bool
variantReaches tydefs seen (Variant _ payload) target = match payload
  ConPos tys => anyTyReaches tydefs seen tys target
  ConNamed fields _ => anyFieldReaches tydefs seen fields target

tyReaches : List (String, TyDef) -> List String -> Ty -> String -> Bool
tyReaches tydefs seen (TyCon { tyConName = n }) target =
  isSome (lookupAssoc n tydefs) && adtReaches tydefs seen n target
tyReaches tydefs seen (TyApp a b) target =
  tyReaches tydefs seen a target || tyReaches tydefs seen b target
tyReaches tydefs seen (TyFun a b) target =
  tyReaches tydefs seen a target || tyReaches tydefs seen b target
tyReaches tydefs seen (TyTuple ts) target = anyTyReaches tydefs seen ts target
tyReaches tydefs seen (TyEffect _ _ t) target = tyReaches tydefs seen t target
tyReaches tydefs seen (TyConstrained _ t) target =
  tyReaches tydefs seen t target
tyReaches _ _ _ _ = False

anyTyReaches : List (String, TyDef) -> List String -> List Ty -> String -> Bool
anyTyReaches _ _ [] _ = False
anyTyReaches tydefs seen (t :: rest) target =
  tyReaches tydefs seen t target || anyTyReaches tydefs seen rest target

anyFieldReaches : List (String, TyDef) ->
  List String ->
  List Field ->
  String ->
  Bool
anyFieldReaches _ _ [] _ = False
anyFieldReaches tydefs seen ((Field _ fty) :: rest) target =
  tyReaches tydefs seen fty target || anyFieldReaches tydefs seen rest target

-- Can generating this constructor's payload re-enter `self`, the ADT the
-- constructor belongs to?  Directly (`data T = Leaf | Node T T T`) or
-- transitively through other ADTs, which covers MUTUAL recursion
-- (`data A = A0 | A1 B` / `data B = B1 A`).  A payload that merely mentions
-- some OTHER user ADT with no path back (`data Fin = F0 | F1 Leaf`) is NOT
-- recursive and keeps its uniform weight.
variantRecursive : List (String, TyDef) -> String -> Variant -> Bool
variantRecursive tydefs self v = variantReaches tydefs [] v self

-- Can generating a value of this type diverge — i.e. does it mention an ADT
-- that lies on a cycle of the mention graph?  This is the element-type test
-- behind `listLenBound`, where there is no "owning ADT" to ask about.
tyCanDiverge : List (String, TyDef) -> Ty -> Bool
tyCanDiverge tydefs (TyCon { tyConName = n }) =
  isSome (lookupAssoc n tydefs) && adtStepReaches tydefs [] n n
tyCanDiverge tydefs (TyApp a b) = tyCanDiverge tydefs a || tyCanDiverge tydefs b
tyCanDiverge tydefs (TyFun a b) = tyCanDiverge tydefs a || tyCanDiverge tydefs b
tyCanDiverge tydefs (TyTuple ts) = anyTyCanDiverge tydefs ts
tyCanDiverge tydefs (TyEffect _ _ t) = tyCanDiverge tydefs t
tyCanDiverge tydefs (TyConstrained _ t) = tyCanDiverge tydefs t
tyCanDiverge _ _ = False

anyTyCanDiverge : List (String, TyDef) -> List Ty -> Bool
anyTyCanDiverge _ [] = False
anyTyCanDiverge tydefs (t :: rest) =
  tyCanDiverge tydefs t || anyTyCanDiverge tydefs rest

-- ── size-aware LIST/ARRAY length (#2294 follow-up) ──────────────────────────
-- `pickVariant`'s weighting cannot help a SINGLE-constructor recursive ADT —
-- `data Rose = Rose Int (List Rose)` has one weight, so `allEqualInts` is
-- trivially true and the uniform fast path always fires.  `Rose`'s divergence
-- never came from constructor choice at all: it came from this length draw.
-- `randIntRange 0 7` has mean 3.5, so every `Rose` averages 3.5 recursive
-- children — wildly supercritical, and the runner dies with `E-STACK-OVERFLOW`.
--
-- So the length bound shrinks with depth, the same shape `pickVariant` uses:
--
--   bound(depth, t) = listLenMax                       -- depth 0, or t cannot diverge
--                     0                                -- depth >= maxGenDepth
--                     max 1 (listLenMax - 2 * depth)   -- otherwise
--
-- Expected recursive-child count per node, for `List`-mediated self-recursion
-- (a node generated at depth d draws its list at depth d + 1, mean bound/2):
--
--   depth 1 → bound 5 → mean 2.5     depth 3 → bound 1 → mean 0.5
--   depth 2 → bound 3 → mean 1.5     depth ≥ 3 → bound 1 → mean 0.5
--
-- i.e. SUBCRITICAL (mean < 1) from depth 3 on, so the process dies out almost
-- surely with finite expected size (≈ 1 + 2.5 + 3.75 + 1.875 + … ≈ 11 nodes),
-- while depths 1–2 stay wide enough to reach the shapes props care about.  The
-- `maxGenDepth` arm is the same backstop `variantWeights` uses — a guarantee
-- rather than a probability — not the mechanism.
--
-- 🚨 At depth 0, and at ANY depth for an element type that cannot diverge
-- (`List Int`, `List Bool`, `List Leaf`), the draw is `randIntRange 0
-- listLenMax` — the exact pre-existing `randIntRange 0 7`, same range, same
-- single RNG step.  This is the uniform fast path `pickVariant` has, expressed
-- for lengths.
listLenMax : Int
listLenMax = 7

listLenBound : List (String, TyDef) -> Int -> Ty -> Int
listLenBound tydefs depth t =
  if depth <= 0 || not (tyCanDiverge tydefs t) then
    listLenMax
  else if depth >= maxGenDepth then
    0
  else
    max 1 (listLenMax - 2 * depth)

variantWeights : List (String, TyDef) ->
  String ->
  Int ->
  List Variant ->
  List Int
variantWeights _ _ _ [] = []
variantWeights tydefs self depth (v :: rest) =
  let w =
    if variantRecursive tydefs self v then
      if depth >= maxGenDepth then 0 else max 1 (recWeight0 - depth)
    else
      recWeight0
  w :: variantWeights tydefs self depth rest

sumL : List Int -> Int
sumL [] = 0
sumL (x :: rest) = x + sumL rest

allEqualInts : List Int -> Bool
allEqualInts [] = True
allEqualInts (x :: rest) = allEqualGo x rest

allEqualGo : Int -> List Int -> Bool
allEqualGo _ [] = True
allEqualGo x (y :: rest) = x == y && allEqualGo x rest

-- Walk the cumulative weights: `r` is a draw in `[0, total)`.
pickWeighted : List Variant -> List Int -> Int -> Variant
pickWeighted (v :: rest) (w :: ws) r =
  if r < w then v else pickWeighted rest ws (r - w)
pickWeighted (v :: _) [] _ = v
pickWeighted [] _ _ = panic "prop_runner: data type with no constructors"

pickVariant : List (String, TyDef) ->
  String ->
  Int ->
  List Variant ->
  <e> Variant
pickVariant tydefs self depth variants =
  let ws = variantWeights tydefs self depth variants
  -- Uniform fast path — depth 0, or an ADT no constructor of which can reach
  -- the ADT itself.
  -- Draws exactly the value the pre-#2294 runner drew, from the same range.
  if allEqualInts ws then
    nthList variants (randIntRange 0 (listLen variants - 1))
  else
    let total = sumL ws
    if total <= 0 then
      -- Every constructor recurses (`data S = S S`): there is no finite value
      -- to generate, so fall back to the uniform pick and let the existing
      -- overflow report the fact rather than inventing a different failure.
      nthList variants (randIntRange 0 (listLen variants - 1))
    else
      pickWeighted variants ws (randIntRange 0 (total - 1))

nthList : List a -> Int -> a
nthList (x :: _) 0 = x
nthList (_ :: xs) n = nthList xs (n - 1)
nthList [] _ = panic "nthList: index out of range"

-- ── shrinking (native) ──────────────────────────────────────────────────────

shrinkValue : Ty -> Value e -> List (Value e)
shrinkValue ty v = match (ty, v)
  (TyCon { tyConName = "Int" }, VInt n) => shrinkInt n
  (TyCon { tyConName = "Bool" }, VBool True) => [VBool False]
  (TyCon { tyConName = "Bool" }, VBool False) => []
  (TyCon { tyConName = "Float" }, VFloat x) =>
    if x == 0.0 then [] else [VFloat 0.0, VFloat (x / 2.0)]
  (TyCon { tyConName = "String" }, VString s) =>
    if s == "" then [] else [VString (stringSlice 0 (stringLength s / 2) s)]
  (TyApp (TyCon { tyConName = "List" }) _, VList []) => []
  (TyApp (TyCon { tyConName = "List" }) _, VList (_ :: rest)) => [VList rest]
  (TyApp (TyCon { tyConName = "Option" }) _, VCon "None" []) => []
  (TyApp (TyCon { tyConName = "Option" }) _, VCon "Some" _) => [VCon "None" []]
  _ => []

shrinkInt : Int -> List (Value e)
shrinkInt 0 = []
shrinkInt n =
  let cands = [0, n / 2, n + (if n > 0 then -1 else 1)]
  map VInt (filterList (/= n) cands)

-- ── prop evaluation ──────────────────────────────────────────────────────────
-- evalEnv is the program's binding environment (List (String, Value)); each
-- prop body is evaluated in a frame extending it with the generated inputs.

checkProp : List (String, Value e) -> Expr -> List (String, Value e) -> <e> Bool
checkProp evalEnv body inputs =
  let env = extendEnv (EvalEnv [[]]) (inputs ++ evalEnv)
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

runProp : List (String, TyDef) ->
  List (String, Value e) ->
  Decl ->
  Int ->
  String ->
  List (String, Int) ->
  <IO> Bool
runProp tydefs evalEnv (DProp _ name params body) maxTests target propLines =
  let line = lineOfPropName name propLines
  let _ = putStr "\{propLocPrefix target line}Testing \{escStrLocal name} ... "
  -- #2295: capture the prop's OWN RNG state at the moment it starts drawing
  -- (before any generation for this prop happens) — reseeding to this exact
  -- value via `--seed` reproduces this prop's draws byte-for-byte regardless
  -- of what ran before it, so it is the number to print on failure.
  let seedAtStart = !propRngStateRef
  match findFailure tydefs evalEnv params body maxTests 1
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
runProp tydefs evalEnv _ maxTests target propLines = True

findFailure : List (String, TyDef) ->
  List (String, Value e) ->
  List PropParam ->
  Expr ->
  Int ->
  Int ->
  <e> PropOutcome (Value e)
findFailure tydefs evalEnv params body maxTests run
  | run > maxTests = PropPassed
  | otherwise =
    let inputs = genInputs tydefs params
    findFailureStep
      tydefs
      evalEnv
      params
      body
      maxTests
      run
      inputs
      (checkProp evalEnv body inputs)

findFailureStep : List (String, TyDef) ->
  List (String, Value e) ->
  List PropParam ->
  Expr ->
  Int ->
  Int ->
  List (String, Value e) ->
  Bool ->
  <e> PropOutcome (Value e)
findFailureStep tydefs evalEnv params body maxTests run _ True =
  findFailure tydefs evalEnv params body maxTests (run + 1)
findFailureStep _ evalEnv params body _ run inputs False =
  let (shrunk, fuelExhausted) = shrinkLoop evalEnv params body inputs
  PropFailed run shrunk fuelExhausted

genInputs : List (String, TyDef) -> List PropParam -> <e> List (String, Value e)
genInputs _ [] = []
genInputs tydefs ((PropParam x _ ty) :: rest) =
  (x, genForType tydefs [] 0 ty) :: genInputs tydefs rest

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
shrinkLoop : List (String, Value e) ->
  List PropParam ->
  Expr ->
  List (String, Value e) ->
  <e> (List (String, Value e), Bool)
shrinkLoop evalEnv params body candidate =
  shrinkLoopFuel evalEnv params body candidate shrinkFuel

shrinkLoopFuel : List (String, Value e) ->
  List PropParam ->
  Expr ->
  List (String, Value e) ->
  Int ->
  <e> (List (String, Value e), Bool)
shrinkLoopFuel _ _ _ candidate 0 = (candidate, True)
shrinkLoopFuel evalEnv params body candidate fuel = match (tryShrinkOne
  evalEnv
  params
  body
  candidate
  0)
  Some better => shrinkLoopFuel evalEnv params body better (fuel - 1)
  None => (candidate, False)

-- Try each param in order; return the first candidate where some smaller value
-- still fails the prop.
tryShrinkOne : List (String, Value e) ->
  List PropParam ->
  Expr ->
  List (String, Value e) ->
  Int ->
  <e> Option (List (String, Value e))
tryShrinkOne evalEnv params body candidate i
  | i >= listLen params = None
  | otherwise =
    let (PropParam x _ ty) = nthList params i
    let currentV = assocVal x candidate
    let smaller = shrinkValue ty currentV
    match findSmaller evalEnv params body candidate x smaller
      Some better => Some better
      None => tryShrinkOne evalEnv params body candidate (i + 1)

findSmaller : List (String, Value e) ->
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

filterProps : List Decl -> List Decl
filterProps decls = filterDecls isProp decls

filterDecls : (Decl -> Bool) -> List Decl -> List Decl
filterDecls _ [] = []
filterDecls p (d :: rest)
  | p d = d :: filterDecls p rest
  | otherwise = filterDecls p rest

-- `medaka test --filter <substring>` (#2295): keep only props whose name
-- contains `substring`. `None` (no `--filter` given) is a no-op.
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
  <IO> Bool
runAllProps cases filterOpt target propLines evalEnv program =
  let props = filterPropsByName filterOpt (filterProps program)
  if isEmptyL props then
    True
  else
    let tydefs = buildTyDefs program
    let results = runEach cases target propLines tydefs evalEnv props
    let nPass = countTrue results
    let nFail = listLen results - nPass
    let _ =
      putStrLn "\n\{intToString nPass} passed, \{intToString nFail} failed"
    nFail == 0

runEach : Int ->
  String ->
  List (String, Int) ->
  List (String, TyDef) ->
  List (String, Value e) ->
  List Decl ->
  <IO> List Bool
runEach _ _ _ _ _ [] = []
runEach cases target propLines tydefs evalEnv (p :: rest) =
  runProp tydefs evalEnv p cases target propLines
    :: runEach cases target propLines tydefs evalEnv rest

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
public export data PropResult = PropResult String Bool String
--                                          name   ok   detail

export
propResultName : PropResult -> String
propResultName (PropResult n _ _) = n

export
propResultPassed : PropResult -> Bool
propResultPassed (PropResult _ p _) = p

export
propResultDetail : PropResult -> String
propResultDetail (PropResult _ _ d) = d

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
  <IO> List PropResult
runAllPropsResults cases filterOpt propLines evalEnv program =
  let props = filterPropsByName filterOpt (filterProps program)
  if isEmptyL props then
    []
  else
    let tydefs = buildTyDefs program
    runEachResult cases propLines tydefs evalEnv props

runEachResult : Int ->
  List (String, Int) ->
  List (String, TyDef) ->
  List (String, Value e) ->
  List Decl ->
  <IO> List PropResult
runEachResult _ _ _ _ [] = []
runEachResult cases propLines tydefs evalEnv ((DProp _ name params body) :: rest) =
  propResultOf
      cases
      (lineOfPropName name propLines)
      name
      (findFailure tydefs evalEnv params body cases 1)
    :: runEachResult cases propLines tydefs evalEnv rest
runEachResult cases propLines tydefs evalEnv (_ :: rest) =
  runEachResult cases propLines tydefs evalEnv rest

propResultOf : Int -> Int -> String -> PropOutcome (Value e) -> PropResult
propResultOf cases _line name PropPassed =
  PropResult name True "\{intToString cases} tests passed"
propResultOf _cases line name (PropFailed run shrunk fuelExhausted) =
  PropResult
    name
    False
    (stringConcat [
      lineDetailPrefix line,
      "failed after ",
      intToString run,
      if run == 1 then
        " test; counterexample: "
      else
        " tests; counterexample: ",
      renderCounterexample shrunk,
      if fuelExhausted then
        " (WARNING: shrink fuel exhausted, counterexample may not be minimal — see #1307)"
      else
        "",
    ])

lineDetailPrefix : Int -> String
lineDetailPrefix 0 = ""
lineDetailPrefix line = "line \{intToString line}: "

renderCounterexample : List (String, Value e) -> String
renderCounterexample [] = ""
renderCounterexample [(x, v)] = stringConcat [x, " = ", ppValue v]
renderCounterexample ((x, v) :: rest) =
  stringConcat [x, " = ", ppValue v, ", ", renderCounterexample rest]

export
hasProps : List Decl -> Bool
hasProps decls = anyDecl isProp decls

anyDecl : (Decl -> Bool) -> List Decl -> Bool
anyDecl _ [] = False
anyDecl p (d :: rest) = p d || anyDecl p rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Expr" false) (mem "DProp" false) (mem "DData" false) (mem "DNewtype" false) (mem "PropParam" false) (mem "Ty" true) (mem "Variant" true) (mem "Field" true) (mem "ConPayload" true))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "eval" false) (mem "extendEnv" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "zipL" false))))
(DTypeSig false "substringMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substringMatch" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig false "propRngStateRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "propRngStateRef" () (EApp (EVar "Ref") (ELit (LInt 123456789))))
(DTypeSig true "seedPropRng" (TyFun (TyCon "Int") (TyCon "Unit")))
(DFunDef false "seedPropRng" ((PVar "n")) (EApp (EApp (EVar "setRef") (EVar "propRngStateRef")) (EVar "n")))
(DTypeSig false "rngNextLocal" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "rngNextLocal" (PWild) (EBlock (DoLet false false (PVar "s") (EBinOp "%" (EBinOp "+" (EBinOp "*" (EUnOp "!" (EVar "propRngStateRef")) (ELit (LInt 1103515245))) (ELit (LInt 12345))) (ELit (LInt 2147483648)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "propRngStateRef")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "randIntRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "randIntRange" ((PVar "lo") (PVar "hi")) (EBlock (DoLet false false (PVar "range") (EBinOp "+" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<=" (EVar "range") (ELit (LInt 0))) (EVar "lo") (EBinOp "+" (EVar "lo") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (EVar "range")))))))
(DTypeSig false "randBoolL" (TyFun (TyCon "Unit") (TyCon "Bool")))
(DFunDef false "randBoolL" (PWild) (EBinOp "==" (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2))) (ELit (LInt 1))))
(DData Public "TyDef" () ((variant "TDData" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant"))))) ())
(DTypeSig false "buildTyDefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef")))))
(DFunDef false "buildTyDefs" ((PList)) (EListLit))
(DFunDef false "buildTyDefs" ((PCons (PVar "d") (PVar "rest"))) (EMatch (EVar "d") (arm (PRec "DData" ((rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataCtors" (PVar "variants"))) false) () (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "TDData") (EVar "params")) (EVar "variants"))) (EApp (EVar "buildTyDefs") (EVar "rest")))) (arm (PRec "DNewtype" ((rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty"))) false) () (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "TDData") (EVar "params")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty"))))))) (EApp (EVar "buildTyDefs") (EVar "rest")))) (arm PWild () (EApp (EVar "buildTyDefs") (EVar "rest")))))
(DTypeSig false "substTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyVar" (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EApp (EVar "TyVar") (EVar "v")))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EVar "map") (EApp (EVar "substTy") (EVar "subst"))) (EVar "ts"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTy" (PWild (PVar "t")) (EVar "t"))
(DTypeSig false "tySpine" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "tySpine" ((PVar "t")) (EApp (EApp (EVar "tySpineGo") (EListLit)) (EVar "t")))
(DTypeSig false "tySpineGo" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")))))))
(DFunDef false "tySpineGo" ((PVar "acc") (PCon "TyApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "tySpineGo") (EBinOp "::" (EVar "a") (EVar "acc"))) (EVar "f")))
(DFunDef false "tySpineGo" ((PVar "acc") (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "acc"))))
(DFunDef false "tySpineGo" (PWild PWild) (EVar "None"))
(DTypeSig false "genForType" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyVar" (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t"))) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "prop_runner: cannot generate values for unbound type variable '")) (EVar "v")) (ELit (LString "'")))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "Int")))) false)) (EApp (EVar "VInt") (EApp (EApp (EVar "randIntRange") (EUnOp "-" (ELit (LInt 1000)))) (ELit (LInt 1000)))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "Bool")))) false)) (EApp (EVar "VBool") (EApp (EVar "randBoolL") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "Float")))) false)) (EApp (EVar "genFloat") (ELit LUnit)))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "Char")))) false)) (EApp (EVar "VChar") (EApp (EVar "genCharStr") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "String")))) false)) (EApp (EVar "VString") (EApp (EVar "genString") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "Unit")))) false)) (EVar "VUnit"))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "List")))) false) (PVar "t"))) (EApp (EVar "VList") (EApp (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "listLenBound") (EVar "tydefs")) (EVar "depth")) (EVar "t"))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Array")))) false) (PVar "t"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "listLenBound") (EVar "tydefs")) (EVar "depth")) (EVar "t")))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Option")))) false) (PVar "t"))) (EIf (EApp (EVar "randBoolL") (ELit LUnit)) (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)) (EApp (EApp (EVar "VCon") (ELit (LString "Some"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t"))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyApp" (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Result")))) false) (PVar "e")) (PVar "a"))) (EIf (EApp (EVar "randBoolL") (ELit LUnit)) (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "a")))) (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "e"))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "VTuple") (EApp (EApp (EApp (EApp (EVar "genTuple") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "ts"))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PVar "ty")) (EApp (EApp (EApp (EApp (EVar "genUserOrFail") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "ty")))
(DTypeSig false "genTuple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genTuple" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "genTuple" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "genTuple") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "rest"))))
(DTypeSig false "genList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "genList" (PWild PWild PWild PWild (PLit (LInt 0))) (EListLit))
(DFunDef false "genList" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PVar "t") (PVar "n")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "genFloat" (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "genFloat" (PWild) (EBlock (DoLet false false (PVar "r") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2000001)))) (DoExpr (EApp (EVar "VFloat") (EBinOp "-" (EBinOp "*" (EApp (EVar "intToFloat") (EVar "r")) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 1000000.0)))) (ELit (LFloat 1.0)))))))
(DTypeSig false "genCharStr" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genCharStr" (PWild) (EApp (EVar "charToStr") (EApp (EVar "charFromCodeU") (EBinOp "+" (ELit (LInt 32)) (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 95)))))))
(DTypeSig false "charFromCodeU" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "charFromCodeU" ((PVar "n")) (EMatch (EApp (EVar "charFromCode") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar " ")))))
(DTypeSig false "genString" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genString" (PWild) (EApp (EVar "stringConcat") (EApp (EVar "genStringGo") (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (ELit (LInt 10))))))
(DTypeSig false "genStringGo" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "genStringGo" ((PLit (LInt 0))) (EListLit))
(DFunDef false "genStringGo" ((PVar "n")) (EBinOp "::" (EApp (EVar "genCharStr") (ELit LUnit)) (EApp (EVar "genStringGo") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "genUserOrFail" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genUserOrFail" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PVar "ty")) (EMatch (EApp (EVar "tySpine") (EVar "ty")) (arm (PCon "Some" (PTuple (PVar "name") (PVar "args"))) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "tydefs")) (arm (PCon "Some" (PVar "tydef")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genUser") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "name")) (EVar "tydef")) (EVar "args"))) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "prop_runner: no generator for type '")) (EVar "name")) (ELit (LString "'. Define an explicit generator (there is no 'Arbitrary' deriver)."))))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "prop_runner: cannot generate values for type"))))))
(DTypeSig false "genUser" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "TyDef") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "genUser" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PVar "name") (PVar "tydef") (PVar "args")) (EBlock (DoLet false false (PVar "args2") (EApp (EApp (EVar "map") (EApp (EVar "substTy") (EVar "subst"))) (EVar "args"))) (DoExpr (EMatch (EVar "tydef") (arm (PCon "TDData" (PVar "params") (PVar "variants")) () (EBlock (DoLet false false (PVar "subst2") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args2"))) (EApp (EApp (EVar "zipL") (EVar "params")) (EVar "args2")) (EListLit))) (DoLet false false (PVar "v") (EApp (EApp (EApp (EApp (EVar "pickVariant") (EVar "tydefs")) (EVar "name")) (EVar "depth")) (EVar "variants"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "genVariant") (EVar "tydefs")) (EVar "subst2")) (EVar "depth")) (EVar "v")))))))))
(DTypeSig false "genVariant" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "Variant") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genVariant" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "Variant" (PVar "cname") (PVar "payload"))) (EMatch (EVar "payload") (arm (PCon "ConPos" (PVar "tys")) () (EApp (EApp (EVar "VCon") (EVar "cname")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EBinOp "+" (EVar "depth") (ELit (LInt 1))))) (EVar "tys")))) (arm (PCon "ConNamed" (PVar "fields") PWild) () (EApp (EApp (EVar "VRecord") (EVar "cname")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "genField") (EVar "tydefs")) (EVar "subst")) (EBinOp "+" (EVar "depth") (ELit (LInt 1))))) (EVar "fields"))))))
(DTypeSig false "genField" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "Field") (TyEffect () (Some "e") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genField" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "Field" (PVar "fname") (PVar "fty"))) (ETuple (EVar "fname") (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "fty"))))
(DTypeSig false "recWeight0" (TyCon "Int"))
(DFunDef false "recWeight0" () (ELit (LInt 6)))
(DTypeSig false "maxGenDepth" (TyCon "Int"))
(DFunDef false "maxGenDepth" () (ELit (LInt 24)))
(DTypeSig false "memberStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "memberStr" (PWild (PList)) (EVar "False"))
(DFunDef false "memberStr" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "memberStr") (EVar "x")) (EVar "rest"))))
(DTypeSig false "adtReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "adtReaches" ((PVar "tydefs") (PVar "seen") (PVar "src") (PVar "target")) (EBinOp "||" (EBinOp "==" (EVar "src") (EVar "target")) (EApp (EApp (EApp (EApp (EVar "adtStepReaches") (EVar "tydefs")) (EVar "seen")) (EVar "src")) (EVar "target"))))
(DTypeSig false "adtStepReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "adtStepReaches" ((PVar "tydefs") (PVar "seen") (PVar "src") (PVar "target")) (EIf (EApp (EApp (EVar "memberStr") (EVar "src")) (EVar "seen")) (EVar "False") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EVar "tydefs")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PCon "TDData" PWild (PVar "variants"))) () (EApp (EApp (EApp (EApp (EVar "anyVariantReaches") (EVar "tydefs")) (EBinOp "::" (EVar "src") (EVar "seen"))) (EVar "variants")) (EVar "target"))))))
(DTypeSig false "anyVariantReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "anyVariantReaches" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyVariantReaches" ((PVar "tydefs") (PVar "seen") (PCons (PVar "v") (PVar "rest")) (PVar "target")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "variantReaches") (EVar "tydefs")) (EVar "seen")) (EVar "v")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "anyVariantReaches") (EVar "tydefs")) (EVar "seen")) (EVar "rest")) (EVar "target"))))
(DTypeSig false "variantReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Variant") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "variantReaches" ((PVar "tydefs") (PVar "seen") (PCon "Variant" PWild (PVar "payload")) (PVar "target")) (EMatch (EVar "payload") (arm (PCon "ConPos" (PVar "tys")) () (EApp (EApp (EApp (EApp (EVar "anyTyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "tys")) (EVar "target"))) (arm (PCon "ConNamed" (PVar "fields") PWild) () (EApp (EApp (EApp (EApp (EVar "anyFieldReaches") (EVar "tydefs")) (EVar "seen")) (EVar "fields")) (EVar "target")))))
(DTypeSig false "tyReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false) (PVar "target")) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tydefs"))) (EApp (EApp (EApp (EApp (EVar "adtReaches") (EVar "tydefs")) (EVar "seen")) (EVar "n")) (EVar "target"))))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PCon "TyApp" (PVar "a") (PVar "b")) (PVar "target")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "a")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "b")) (EVar "target"))))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PCon "TyFun" (PVar "a") (PVar "b")) (PVar "target")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "a")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "b")) (EVar "target"))))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PCon "TyTuple" (PVar "ts")) (PVar "target")) (EApp (EApp (EApp (EApp (EVar "anyTyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "ts")) (EVar "target")))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PCon "TyEffect" PWild PWild (PVar "t")) (PVar "target")) (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "t")) (EVar "target")))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PCon "TyConstrained" PWild (PVar "t")) (PVar "target")) (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "t")) (EVar "target")))
(DFunDef false "tyReaches" (PWild PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyTyReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "anyTyReaches" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyTyReaches" ((PVar "tydefs") (PVar "seen") (PCons (PVar "t") (PVar "rest")) (PVar "target")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "t")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "anyTyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "rest")) (EVar "target"))))
(DTypeSig false "anyFieldReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "anyFieldReaches" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyFieldReaches" ((PVar "tydefs") (PVar "seen") (PCons (PCon "Field" PWild (PVar "fty")) (PVar "rest")) (PVar "target")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "fty")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "anyFieldReaches") (EVar "tydefs")) (EVar "seen")) (EVar "rest")) (EVar "target"))))
(DTypeSig false "variantRecursive" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyCon "String") (TyFun (TyCon "Variant") (TyCon "Bool")))))
(DFunDef false "variantRecursive" ((PVar "tydefs") (PVar "self") (PVar "v")) (EApp (EApp (EApp (EApp (EVar "variantReaches") (EVar "tydefs")) (EListLit)) (EVar "v")) (EVar "self")))
(DTypeSig false "tyCanDiverge" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tydefs"))) (EApp (EApp (EApp (EApp (EVar "adtStepReaches") (EVar "tydefs")) (EListLit)) (EVar "n")) (EVar "n"))))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "a")) (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "b"))))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "a")) (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "b"))))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "anyTyCanDiverge") (EVar "tydefs")) (EVar "ts")))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "t")))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "t")))
(DFunDef false "tyCanDiverge" (PWild PWild) (EVar "False"))
(DTypeSig false "anyTyCanDiverge" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "anyTyCanDiverge" (PWild (PList)) (EVar "False"))
(DFunDef false "anyTyCanDiverge" ((PVar "tydefs") (PCons (PVar "t") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "t")) (EApp (EApp (EVar "anyTyCanDiverge") (EVar "tydefs")) (EVar "rest"))))
(DTypeSig false "listLenMax" (TyCon "Int"))
(DFunDef false "listLenMax" () (ELit (LInt 7)))
(DTypeSig false "listLenBound" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "Int")))))
(DFunDef false "listLenBound" ((PVar "tydefs") (PVar "depth") (PVar "t")) (EIf (EBinOp "||" (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "t")))) (EVar "listLenMax") (EIf (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (ELit (LInt 0)) (EApp (EApp (EVar "max") (ELit (LInt 1))) (EBinOp "-" (EVar "listLenMax") (EBinOp "*" (ELit (LInt 2)) (EVar "depth")))))))
(DTypeSig false "variantWeights" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "variantWeights" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "variantWeights" ((PVar "tydefs") (PVar "self") (PVar "depth") (PCons (PVar "v") (PVar "rest"))) (EBlock (DoLet false false (PVar "w") (EIf (EApp (EApp (EApp (EVar "variantRecursive") (EVar "tydefs")) (EVar "self")) (EVar "v")) (EIf (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (ELit (LInt 0)) (EApp (EApp (EVar "max") (ELit (LInt 1))) (EBinOp "-" (EVar "recWeight0") (EVar "depth")))) (EVar "recWeight0"))) (DoExpr (EBinOp "::" (EVar "w") (EApp (EApp (EApp (EApp (EVar "variantWeights") (EVar "tydefs")) (EVar "self")) (EVar "depth")) (EVar "rest"))))))
(DTypeSig false "sumL" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "sumL" ((PList)) (ELit (LInt 0)))
(DFunDef false "sumL" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "+" (EVar "x") (EApp (EVar "sumL") (EVar "rest"))))
(DTypeSig false "allEqualInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "allEqualInts" ((PList)) (EVar "True"))
(DFunDef false "allEqualInts" ((PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "allEqualGo") (EVar "x")) (EVar "rest")))
(DTypeSig false "allEqualGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "allEqualGo" (PWild (PList)) (EVar "True"))
(DFunDef false "allEqualGo" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "allEqualGo") (EVar "x")) (EVar "rest"))))
(DTypeSig false "pickWeighted" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Variant")))))
(DFunDef false "pickWeighted" ((PCons (PVar "v") (PVar "rest")) (PCons (PVar "w") (PVar "ws")) (PVar "r")) (EIf (EBinOp "<" (EVar "r") (EVar "w")) (EVar "v") (EApp (EApp (EApp (EVar "pickWeighted") (EVar "rest")) (EVar "ws")) (EBinOp "-" (EVar "r") (EVar "w")))))
(DFunDef false "pickWeighted" ((PCons (PVar "v") PWild) (PList) PWild) (EVar "v"))
(DFunDef false "pickWeighted" ((PList) PWild PWild) (EApp (EVar "panic") (ELit (LString "prop_runner: data type with no constructors"))))
(DTypeSig false "pickVariant" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyEffect () (Some "e") (TyCon "Variant")))))))
(DFunDef false "pickVariant" ((PVar "tydefs") (PVar "self") (PVar "depth") (PVar "variants")) (EBlock (DoLet false false (PVar "ws") (EApp (EApp (EApp (EApp (EVar "variantWeights") (EVar "tydefs")) (EVar "self")) (EVar "depth")) (EVar "variants"))) (DoExpr (EIf (EApp (EVar "allEqualInts") (EVar "ws")) (EApp (EApp (EVar "nthList") (EVar "variants")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "listLen") (EVar "variants")) (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "total") (EApp (EVar "sumL") (EVar "ws"))) (DoExpr (EIf (EBinOp "<=" (EVar "total") (ELit (LInt 0))) (EApp (EApp (EVar "nthList") (EVar "variants")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "listLen") (EVar "variants")) (ELit (LInt 1))))) (EApp (EApp (EApp (EVar "pickWeighted") (EVar "variants")) (EVar "ws")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EVar "total") (ELit (LInt 1))))))))))))
(DTypeSig false "nthList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "Int") (TyVar "a"))))
(DFunDef false "nthList" ((PCons (PVar "x") PWild) (PLit (LInt 0))) (EVar "x"))
(DFunDef false "nthList" ((PCons PWild (PVar "xs")) (PVar "n")) (EApp (EApp (EVar "nthList") (EVar "xs")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))
(DFunDef false "nthList" ((PList) PWild) (EApp (EVar "panic") (ELit (LString "nthList: index out of range"))))
(DTypeSig false "shrinkValue" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "shrinkValue" ((PVar "ty") (PVar "v")) (EMatch (ETuple (EVar "ty") (EVar "v")) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "Int")))) false) (PCon "VInt" (PVar "n"))) () (EApp (EVar "shrinkInt") (EVar "n"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "Bool")))) false) (PCon "VBool" (PCon "True"))) () (EListLit (EApp (EVar "VBool") (EVar "False")))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "Bool")))) false) (PCon "VBool" (PCon "False"))) () (EListLit)) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "Float")))) false) (PCon "VFloat" (PVar "x"))) () (EIf (EBinOp "==" (EVar "x") (ELit (LFloat 0.0))) (EListLit) (EListLit (EApp (EVar "VFloat") (ELit (LFloat 0.0))) (EApp (EVar "VFloat") (EBinOp "/" (EVar "x") (ELit (LFloat 2.0))))))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "String")))) false) (PCon "VString" (PVar "s"))) () (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EListLit) (EListLit (EApp (EVar "VString") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))) (EVar "s")))))) (arm (PTuple (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "List")))) false) PWild) (PCon "VList" (PList))) () (EListLit)) (arm (PTuple (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "List")))) false) PWild) (PCon "VList" (PCons PWild (PVar "rest")))) () (EListLit (EApp (EVar "VList") (EVar "rest")))) (arm (PTuple (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Option")))) false) PWild) (PCon "VCon" (PLit (LString "None")) (PList))) () (EListLit)) (arm (PTuple (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Option")))) false) PWild) (PCon "VCon" (PLit (LString "Some")) PWild)) () (EListLit (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)))) (arm PWild () (EListLit))))
(DTypeSig false "shrinkInt" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "shrinkInt" ((PLit (LInt 0))) (EListLit))
(DFunDef false "shrinkInt" ((PVar "n")) (EBlock (DoLet false false (PVar "cands") (EListLit (ELit (LInt 0)) (EBinOp "/" (EVar "n") (ELit (LInt 2))) (EBinOp "+" (EVar "n") (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "map") (EVar "VInt")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "n")))) (EVar "cands"))))))
(DTypeSig false "checkProp" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "checkProp" ((PVar "evalEnv") (PVar "body") (PVar "inputs")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EBinOp "++" (EVar "inputs") (EVar "evalEnv")))) (DoExpr (EMatch (EApp (EVar "force") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))) (arm (PCon "VBool" (PVar "b")) () (EVar "b")) (arm PWild () (EVar "False"))))))
(DData Public "PropOutcome" ("v") ((variant "PropPassed" (ConPos)) (variant "PropFailed" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "v"))) (TyCon "Bool")))) ())
(DTypeSig false "lineOfPropName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int"))))
(DFunDef false "lineOfPropName" ((PVar "name") (PVar "propLines")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "propLines")) (arm (PCon "Some" (PVar "l")) () (EVar "l")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "propLocPrefix" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "propLocPrefix" (PWild (PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "propLocPrefix" ((PVar "target") (PVar "line")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))))
(DTypeSig false "runProp" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runProp" ((PVar "tydefs") (PVar "evalEnv") (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "maxTests") (PVar "target") (PVar "propLines")) (EBlock (DoLet false false (PVar "line") (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "propLocPrefix") (EVar "target")) (EVar "line")))) (ELit (LString "Testing "))) (EApp (EVar "display") (EApp (EVar "escStrLocal") (EVar "name")))) (ELit (LString " ... "))))) (DoLet false false (PVar "seedAtStart") (EUnOp "!" (EVar "propRngStateRef"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (ELit (LInt 1))) (arm (PCon "PropPassed") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "OK (")) (EApp (EVar "intToString") (EVar "maxTests"))) (ELit (LString " tests)"))))) (DoExpr (EVar "True")))) (arm (PCon "PropFailed" (PVar "run") (PVar "shrunk") (PVar "fuelExhausted")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAILED after ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "run")))) (ELit (LString ""))) (EApp (EVar "display") (EIf (EBinOp "==" (EVar "run") (ELit (LInt 1))) (ELit (LString " test")) (ELit (LString " tests"))))) (ELit (LString ""))))) (DoLet false false PWild (EIf (EVar "fuelExhausted") (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "  WARNING: shrink fuel exhausted after ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "shrinkFuel")))) (ELit (LString " steps; the counterexample below may not be minimal, and a shrink arm is probably cycling (see #1307).")))) (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  Seed: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "seedAtStart")))) (ELit (LString " (rerun with: medaka test --seed "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "seedAtStart")))) (ELit (LString " --filter "))) (EApp (EVar "display") (EApp (EVar "escStrLocal") (EVar "name")))) (ELit (LString " <file>)"))))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  Counterexample:")))) (DoLet false false PWild (EApp (EVar "printCounterexample") (EVar "shrunk"))) (DoExpr (EVar "False"))))))))
(DFunDef false "runProp" ((PVar "tydefs") (PVar "evalEnv") PWild (PVar "maxTests") (PVar "target") (PVar "propLines")) (EVar "True"))
(DTypeSig false "findFailure" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "findFailure" ((PVar "tydefs") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run")) (EIf (EBinOp ">" (EVar "run") (EVar "maxTests")) (EVar "PropPassed") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "inputs") (EApp (EApp (EVar "genInputs") (EVar "tydefs")) (EVar "params"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailureStep") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EVar "run")) (EVar "inputs")) (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "inputs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findFailureStep" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Bool") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "findFailureStep" ((PVar "tydefs") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run") PWild (PCon "True")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EBinOp "+" (EVar "run") (ELit (LInt 1)))))
(DFunDef false "findFailureStep" (PWild (PVar "evalEnv") (PVar "params") (PVar "body") PWild (PVar "run") (PVar "inputs") (PCon "False")) (EBlock (DoLet false false (PTuple (PVar "shrunk") (PVar "fuelExhausted")) (EApp (EApp (EApp (EApp (EVar "shrinkLoop") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "inputs"))) (DoExpr (EApp (EApp (EApp (EVar "PropFailed") (EVar "run")) (EVar "shrunk")) (EVar "fuelExhausted")))))
(DTypeSig false "genInputs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genInputs" (PWild (PList)) (EListLit))
(DFunDef false "genInputs" ((PVar "tydefs") (PCons (PCon "PropParam" (PVar "x") PWild (PVar "ty")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "x") (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EListLit)) (ELit (LInt 0))) (EVar "ty"))) (EApp (EApp (EVar "genInputs") (EVar "tydefs")) (EVar "rest"))))
(DTypeSig false "printCounterexample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printCounterexample" ((PList)) (ELit LUnit))
(DFunDef false "printCounterexample" ((PCons (PTuple (PVar "x") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "ppValue") (EVar "v")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "printCounterexample") (EVar "rest")))))
(DTypeSig false "escStrLocal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStrLocal" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DTypeSig false "shrinkFuel" (TyCon "Int"))
(DFunDef false "shrinkFuel" () (ELit (LInt 10000)))
(DTypeSig false "shrinkLoop" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "Bool"))))))))
(DFunDef false "shrinkLoop" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate")) (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoopFuel") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "shrinkFuel")))
(DTypeSig false "shrinkLoopFuel" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "Bool")))))))))
(DFunDef false "shrinkLoopFuel" (PWild PWild PWild (PVar "candidate") (PLit (LInt 0))) (ETuple (EVar "candidate") (EVar "True")))
(DFunDef false "shrinkLoopFuel" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "fuel")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (ELit (LInt 0))) (arm (PCon "Some" (PVar "better")) () (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoopFuel") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "better")) (EBinOp "-" (EVar "fuel") (ELit (LInt 1))))) (arm (PCon "None") () (ETuple (EVar "candidate") (EVar "False")))))
(DTypeSig false "tryShrinkOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))))))
(DFunDef false "tryShrinkOne" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "listLen") (EVar "params"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PCon "PropParam" (PVar "x") PWild (PVar "ty")) (EApp (EApp (EVar "nthList") (EVar "params")) (EVar "i"))) (DoLet false false (PVar "currentV") (EApp (EApp (EVar "assocVal") (EVar "x")) (EVar "candidate"))) (DoLet false false (PVar "smaller") (EApp (EApp (EVar "shrinkValue") (EVar "ty")) (EVar "currentV"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findSmaller") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "x")) (EVar "smaller")) (arm (PCon "Some" (PVar "better")) () (EApp (EVar "Some") (EVar "better"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findSmaller" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
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
(DTypeSig false "filterProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "filterProps" ((PVar "decls")) (EApp (EApp (EVar "filterDecls") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "filterDecls" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterDecls" (PWild (PList)) (EListLit))
(DFunDef false "filterDecls" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "d")) (EBinOp "::" (EVar "d") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterPropsByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterPropsByName" ((PCon "None") (PVar "decls")) (EVar "decls"))
(DFunDef false "filterPropsByName" ((PCon "Some" (PVar "sub")) (PVar "decls")) (EApp (EApp (EVar "filterDecls") (EApp (EVar "propNameMatches") (EVar "sub"))) (EVar "decls")))
(DTypeSig false "propNameMatches" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "propNameMatches" ((PVar "sub") (PCon "DProp" PWild (PVar "name") PWild PWild)) (EApp (EApp (EVar "substringMatch") (EVar "sub")) (EVar "name")))
(DFunDef false "propNameMatches" (PWild PWild) (EVar "False"))
(DTypeSig true "runAllProps" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runAllProps" ((PVar "cases") (PVar "filterOpt") (PVar "target") (PVar "propLines") (PVar "evalEnv") (PVar "program")) (EBlock (DoLet false false (PVar "props") (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "program")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "props")) (EVar "True") (EBlock (DoLet false false (PVar "tydefs") (EApp (EVar "buildTyDefs") (EVar "program"))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEach") (EVar "cases")) (EVar "target")) (EVar "propLines")) (EVar "tydefs")) (EVar "evalEnv")) (EVar "props"))) (DoLet false false (PVar "nPass") (EApp (EVar "countTrue") (EVar "results"))) (DoLet false false (PVar "nFail") (EBinOp "-" (EApp (EVar "listLen") (EVar "results")) (EVar "nPass"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nPass")))) (ELit (LString " passed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nFail")))) (ELit (LString " failed"))))) (DoExpr (EBinOp "==" (EVar "nFail") (ELit (LInt 0)))))))))
(DTypeSig false "runEach" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Bool"))))))))))
(DFunDef false "runEach" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "runEach" ((PVar "cases") (PVar "target") (PVar "propLines") (PVar "tydefs") (PVar "evalEnv") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProp") (EVar "tydefs")) (EVar "evalEnv")) (EVar "p")) (EVar "cases")) (EVar "target")) (EVar "propLines")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEach") (EVar "cases")) (EVar "target")) (EVar "propLines")) (EVar "tydefs")) (EVar "evalEnv")) (EVar "rest"))))
(DTypeSig false "countTrue" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyCon "Int")))
(DFunDef false "countTrue" ((PList)) (ELit (LInt 0)))
(DFunDef false "countTrue" ((PCons (PCon "True") (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countTrue") (EVar "rest"))))
(DFunDef false "countTrue" ((PCons (PCon "False") (PVar "rest"))) (EApp (EVar "countTrue") (EVar "rest")))
(DData Public "PropResult" () ((variant "PropResult" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "String")))) ())
(DTypeSig true "propResultName" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "propResultName" ((PCon "PropResult" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "propResultPassed" (TyFun (TyCon "PropResult") (TyCon "Bool")))
(DFunDef false "propResultPassed" ((PCon "PropResult" PWild (PVar "p") PWild)) (EVar "p"))
(DTypeSig true "propResultDetail" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "propResultDetail" ((PCon "PropResult" PWild PWild (PVar "d"))) (EVar "d"))
(DTypeSig true "runAllPropsResults" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runAllPropsResults" ((PVar "cases") (PVar "filterOpt") (PVar "propLines") (PVar "evalEnv") (PVar "program")) (EBlock (DoLet false false (PVar "props") (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "program")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "props")) (EListLit) (EBlock (DoLet false false (PVar "tydefs") (EApp (EVar "buildTyDefs") (EVar "program"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EVar "tydefs")) (EVar "evalEnv")) (EVar "props"))))))))
(DTypeSig false "runEachResult" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runEachResult" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "runEachResult" ((PVar "cases") (PVar "propLines") (PVar "tydefs") (PVar "evalEnv") (PCons (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "propResultOf") (EVar "cases")) (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "cases")) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EVar "tydefs")) (EVar "evalEnv")) (EVar "rest"))))
(DFunDef false "runEachResult" ((PVar "cases") (PVar "propLines") (PVar "tydefs") (PVar "evalEnv") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EVar "tydefs")) (EVar "evalEnv")) (EVar "rest")))
(DTypeSig false "propResultOf" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "PropResult"))))))
(DFunDef false "propResultOf" ((PVar "cases") (PVar "_line") (PVar "name") (PCon "PropPassed")) (EApp (EApp (EApp (EVar "PropResult") (EVar "name")) (EVar "True")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "cases")))) (ELit (LString " tests passed")))))
(DFunDef false "propResultOf" ((PVar "_cases") (PVar "line") (PVar "name") (PCon "PropFailed" (PVar "run") (PVar "shrunk") (PVar "fuelExhausted"))) (EApp (EApp (EApp (EVar "PropResult") (EVar "name")) (EVar "False")) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "lineDetailPrefix") (EVar "line")) (ELit (LString "failed after ")) (EApp (EVar "intToString") (EVar "run")) (EIf (EBinOp "==" (EVar "run") (ELit (LInt 1))) (ELit (LString " test; counterexample: ")) (ELit (LString " tests; counterexample: "))) (EApp (EVar "renderCounterexample") (EVar "shrunk")) (EIf (EVar "fuelExhausted") (ELit (LString " (WARNING: shrink fuel exhausted, counterexample may not be minimal — see #1307)")) (ELit (LString "")))))))
(DTypeSig false "lineDetailPrefix" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "lineDetailPrefix" ((PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "lineDetailPrefix" ((PVar "line")) (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))))
(DTypeSig false "renderCounterexample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "String")))
(DFunDef false "renderCounterexample" ((PList)) (ELit (LString "")))
(DFunDef false "renderCounterexample" ((PList (PTuple (PVar "x") (PVar "v")))) (EApp (EVar "stringConcat") (EListLit (EVar "x") (ELit (LString " = ")) (EApp (EVar "ppValue") (EVar "v")))))
(DFunDef false "renderCounterexample" ((PCons (PTuple (PVar "x") (PVar "v")) (PVar "rest"))) (EApp (EVar "stringConcat") (EListLit (EVar "x") (ELit (LString " = ")) (EApp (EVar "ppValue") (EVar "v")) (ELit (LString ", ")) (EApp (EVar "renderCounterexample") (EVar "rest")))))
(DTypeSig true "hasProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasProps" ((PVar "decls")) (EApp (EApp (EVar "anyDecl") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "anyDecl" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "anyDecl" (PWild (PList)) (EVar "False"))
(DFunDef false "anyDecl" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "p") (EVar "d")) (EApp (EApp (EVar "anyDecl") (EVar "p")) (EVar "rest"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Expr" false) (mem "DProp" false) (mem "DData" false) (mem "DNewtype" false) (mem "PropParam" false) (mem "Ty" true) (mem "Variant" true) (mem "Field" true) (mem "ConPayload" true))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "eval" false) (mem "extendEnv" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "zipL" false))))
(DTypeSig false "substringMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "substringMatch" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig false "propRngStateRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "propRngStateRef" () (EApp (EVar "Ref") (ELit (LInt 123456789))))
(DTypeSig true "seedPropRng" (TyFun (TyCon "Int") (TyCon "Unit")))
(DFunDef false "seedPropRng" ((PVar "n")) (EApp (EApp (EVar "setRef") (EVar "propRngStateRef")) (EVar "n")))
(DTypeSig false "rngNextLocal" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "rngNextLocal" (PWild) (EBlock (DoLet false false (PVar "s") (EBinOp "%" (EBinOp "+" (EBinOp "*" (EUnOp "!" (EVar "propRngStateRef")) (ELit (LInt 1103515245))) (ELit (LInt 12345))) (ELit (LInt 2147483648)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "propRngStateRef")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "randIntRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "randIntRange" ((PVar "lo") (PVar "hi")) (EBlock (DoLet false false (PVar "range") (EBinOp "+" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<=" (EVar "range") (ELit (LInt 0))) (EVar "lo") (EBinOp "+" (EVar "lo") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (EVar "range")))))))
(DTypeSig false "randBoolL" (TyFun (TyCon "Unit") (TyCon "Bool")))
(DFunDef false "randBoolL" (PWild) (EBinOp "==" (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2))) (ELit (LInt 1))))
(DData Public "TyDef" () ((variant "TDData" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant"))))) ())
(DTypeSig false "buildTyDefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef")))))
(DFunDef false "buildTyDefs" ((PList)) (EListLit))
(DFunDef false "buildTyDefs" ((PCons (PVar "d") (PVar "rest"))) (EMatch (EVar "d") (arm (PRec "DData" ((rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataCtors" (PVar "variants"))) false) () (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "TDData") (EVar "params")) (EVar "variants"))) (EApp (EVar "buildTyDefs") (EVar "rest")))) (arm (PRec "DNewtype" ((rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty"))) false) () (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "TDData") (EVar "params")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty"))))))) (EApp (EVar "buildTyDefs") (EVar "rest")))) (arm PWild () (EApp (EVar "buildTyDefs") (EVar "rest")))))
(DTypeSig false "substTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyVar" (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EApp (EVar "TyVar") (EVar "v")))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "substTy") (EVar "subst"))) (EVar "ts"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTy" (PWild (PVar "t")) (EVar "t"))
(DTypeSig false "tySpine" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "tySpine" ((PVar "t")) (EApp (EApp (EVar "tySpineGo") (EListLit)) (EVar "t")))
(DTypeSig false "tySpineGo" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")))))))
(DFunDef false "tySpineGo" ((PVar "acc") (PCon "TyApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "tySpineGo") (EBinOp "::" (EVar "a") (EVar "acc"))) (EVar "f")))
(DFunDef false "tySpineGo" ((PVar "acc") (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "acc"))))
(DFunDef false "tySpineGo" (PWild PWild) (EVar "None"))
(DTypeSig false "genForType" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyVar" (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t"))) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "prop_runner: cannot generate values for unbound type variable '")) (EVar "v")) (ELit (LString "'")))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "Int")))) false)) (EApp (EVar "VInt") (EApp (EApp (EVar "randIntRange") (EUnOp "-" (ELit (LInt 1000)))) (ELit (LInt 1000)))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "Bool")))) false)) (EApp (EVar "VBool") (EApp (EVar "randBoolL") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "Float")))) false)) (EApp (EVar "genFloat") (ELit LUnit)))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "Char")))) false)) (EApp (EVar "VChar") (EApp (EVar "genCharStr") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "String")))) false)) (EApp (EVar "VString") (EApp (EVar "genString") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PRec "TyCon" ((rf "tyConName" (PLit (LString "Unit")))) false)) (EVar "VUnit"))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "List")))) false) (PVar "t"))) (EApp (EVar "VList") (EApp (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "listLenBound") (EVar "tydefs")) (EVar "depth")) (EVar "t"))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Array")))) false) (PVar "t"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "listLenBound") (EVar "tydefs")) (EVar "depth")) (EVar "t")))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Option")))) false) (PVar "t"))) (EIf (EApp (EVar "randBoolL") (ELit LUnit)) (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)) (EApp (EApp (EVar "VCon") (ELit (LString "Some"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t"))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyApp" (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Result")))) false) (PVar "e")) (PVar "a"))) (EIf (EApp (EVar "randBoolL") (ELit LUnit)) (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "a")))) (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "e"))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "VTuple") (EApp (EApp (EApp (EApp (EVar "genTuple") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "ts"))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PVar "ty")) (EApp (EApp (EApp (EApp (EVar "genUserOrFail") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "ty")))
(DTypeSig false "genTuple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genTuple" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "genTuple" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "genTuple") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "rest"))))
(DTypeSig false "genList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "genList" (PWild PWild PWild PWild (PLit (LInt 0))) (EListLit))
(DFunDef false "genList" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PVar "t") (PVar "n")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "t")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "genFloat" (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "genFloat" (PWild) (EBlock (DoLet false false (PVar "r") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2000001)))) (DoExpr (EApp (EVar "VFloat") (EBinOp "-" (EBinOp "*" (EApp (EVar "intToFloat") (EVar "r")) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 1000000.0)))) (ELit (LFloat 1.0)))))))
(DTypeSig false "genCharStr" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genCharStr" (PWild) (EApp (EVar "charToStr") (EApp (EVar "charFromCodeU") (EBinOp "+" (ELit (LInt 32)) (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 95)))))))
(DTypeSig false "charFromCodeU" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "charFromCodeU" ((PVar "n")) (EMatch (EApp (EVar "charFromCode") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar " ")))))
(DTypeSig false "genString" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genString" (PWild) (EApp (EVar "stringConcat") (EApp (EVar "genStringGo") (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (ELit (LInt 10))))))
(DTypeSig false "genStringGo" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "genStringGo" ((PLit (LInt 0))) (EListLit))
(DFunDef false "genStringGo" ((PVar "n")) (EBinOp "::" (EApp (EVar "genCharStr") (ELit LUnit)) (EApp (EVar "genStringGo") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "genUserOrFail" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genUserOrFail" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PVar "ty")) (EMatch (EApp (EVar "tySpine") (EVar "ty")) (arm (PCon "Some" (PTuple (PVar "name") (PVar "args"))) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "tydefs")) (arm (PCon "Some" (PVar "tydef")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genUser") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "name")) (EVar "tydef")) (EVar "args"))) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "prop_runner: no generator for type '")) (EVar "name")) (ELit (LString "'. Define an explicit generator (there is no 'Arbitrary' deriver)."))))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "prop_runner: cannot generate values for type"))))))
(DTypeSig false "genUser" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "TyDef") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "genUser" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PVar "name") (PVar "tydef") (PVar "args")) (EBlock (DoLet false false (PVar "args2") (EApp (EApp (EMethodRef "map") (EApp (EVar "substTy") (EVar "subst"))) (EVar "args"))) (DoExpr (EMatch (EVar "tydef") (arm (PCon "TDData" (PVar "params") (PVar "variants")) () (EBlock (DoLet false false (PVar "subst2") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args2"))) (EApp (EApp (EVar "zipL") (EVar "params")) (EVar "args2")) (EListLit))) (DoLet false false (PVar "v") (EApp (EApp (EApp (EApp (EVar "pickVariant") (EVar "tydefs")) (EVar "name")) (EVar "depth")) (EVar "variants"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "genVariant") (EVar "tydefs")) (EVar "subst2")) (EVar "depth")) (EVar "v")))))))))
(DTypeSig false "genVariant" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "Variant") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genVariant" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "Variant" (PVar "cname") (PVar "payload"))) (EMatch (EVar "payload") (arm (PCon "ConPos" (PVar "tys")) () (EApp (EApp (EVar "VCon") (EVar "cname")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EBinOp "+" (EVar "depth") (ELit (LInt 1))))) (EVar "tys")))) (arm (PCon "ConNamed" (PVar "fields") PWild) () (EApp (EApp (EVar "VRecord") (EVar "cname")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "genField") (EVar "tydefs")) (EVar "subst")) (EBinOp "+" (EVar "depth") (ELit (LInt 1))))) (EVar "fields"))))))
(DTypeSig false "genField" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Int") (TyFun (TyCon "Field") (TyEffect () (Some "e") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genField" ((PVar "tydefs") (PVar "subst") (PVar "depth") (PCon "Field" (PVar "fname") (PVar "fty"))) (ETuple (EVar "fname") (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "depth")) (EVar "fty"))))
(DTypeSig false "recWeight0" (TyCon "Int"))
(DFunDef false "recWeight0" () (ELit (LInt 6)))
(DTypeSig false "maxGenDepth" (TyCon "Int"))
(DFunDef false "maxGenDepth" () (ELit (LInt 24)))
(DTypeSig false "memberStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "memberStr" (PWild (PList)) (EVar "False"))
(DFunDef false "memberStr" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "memberStr") (EVar "x")) (EVar "rest"))))
(DTypeSig false "adtReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "adtReaches" ((PVar "tydefs") (PVar "seen") (PVar "src") (PVar "target")) (EBinOp "||" (EBinOp "==" (EVar "src") (EVar "target")) (EApp (EApp (EApp (EApp (EVar "adtStepReaches") (EVar "tydefs")) (EVar "seen")) (EVar "src")) (EVar "target"))))
(DTypeSig false "adtStepReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "adtStepReaches" ((PVar "tydefs") (PVar "seen") (PVar "src") (PVar "target")) (EIf (EApp (EApp (EVar "memberStr") (EVar "src")) (EVar "seen")) (EVar "False") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EVar "tydefs")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PCon "TDData" PWild (PVar "variants"))) () (EApp (EApp (EApp (EApp (EVar "anyVariantReaches") (EVar "tydefs")) (EBinOp "::" (EVar "src") (EVar "seen"))) (EVar "variants")) (EVar "target"))))))
(DTypeSig false "anyVariantReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "anyVariantReaches" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyVariantReaches" ((PVar "tydefs") (PVar "seen") (PCons (PVar "v") (PVar "rest")) (PVar "target")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "variantReaches") (EVar "tydefs")) (EVar "seen")) (EVar "v")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "anyVariantReaches") (EVar "tydefs")) (EVar "seen")) (EVar "rest")) (EVar "target"))))
(DTypeSig false "variantReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Variant") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "variantReaches" ((PVar "tydefs") (PVar "seen") (PCon "Variant" PWild (PVar "payload")) (PVar "target")) (EMatch (EVar "payload") (arm (PCon "ConPos" (PVar "tys")) () (EApp (EApp (EApp (EApp (EVar "anyTyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "tys")) (EVar "target"))) (arm (PCon "ConNamed" (PVar "fields") PWild) () (EApp (EApp (EApp (EApp (EVar "anyFieldReaches") (EVar "tydefs")) (EVar "seen")) (EVar "fields")) (EVar "target")))))
(DTypeSig false "tyReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false) (PVar "target")) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tydefs"))) (EApp (EApp (EApp (EApp (EVar "adtReaches") (EVar "tydefs")) (EVar "seen")) (EVar "n")) (EVar "target"))))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PCon "TyApp" (PVar "a") (PVar "b")) (PVar "target")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "a")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "b")) (EVar "target"))))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PCon "TyFun" (PVar "a") (PVar "b")) (PVar "target")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "a")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "b")) (EVar "target"))))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PCon "TyTuple" (PVar "ts")) (PVar "target")) (EApp (EApp (EApp (EApp (EVar "anyTyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "ts")) (EVar "target")))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PCon "TyEffect" PWild PWild (PVar "t")) (PVar "target")) (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "t")) (EVar "target")))
(DFunDef false "tyReaches" ((PVar "tydefs") (PVar "seen") (PCon "TyConstrained" PWild (PVar "t")) (PVar "target")) (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "t")) (EVar "target")))
(DFunDef false "tyReaches" (PWild PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyTyReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "anyTyReaches" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyTyReaches" ((PVar "tydefs") (PVar "seen") (PCons (PVar "t") (PVar "rest")) (PVar "target")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "t")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "anyTyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "rest")) (EVar "target"))))
(DTypeSig false "anyFieldReaches" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "anyFieldReaches" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyFieldReaches" ((PVar "tydefs") (PVar "seen") (PCons (PCon "Field" PWild (PVar "fty")) (PVar "rest")) (PVar "target")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "tyReaches") (EVar "tydefs")) (EVar "seen")) (EVar "fty")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "anyFieldReaches") (EVar "tydefs")) (EVar "seen")) (EVar "rest")) (EVar "target"))))
(DTypeSig false "variantRecursive" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyCon "String") (TyFun (TyCon "Variant") (TyCon "Bool")))))
(DFunDef false "variantRecursive" ((PVar "tydefs") (PVar "self") (PVar "v")) (EApp (EApp (EApp (EApp (EVar "variantReaches") (EVar "tydefs")) (EListLit)) (EVar "v")) (EVar "self")))
(DTypeSig false "tyCanDiverge" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tydefs"))) (EApp (EApp (EApp (EApp (EVar "adtStepReaches") (EVar "tydefs")) (EListLit)) (EVar "n")) (EVar "n"))))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "a")) (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "b"))))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "a")) (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "b"))))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "anyTyCanDiverge") (EVar "tydefs")) (EVar "ts")))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "t")))
(DFunDef false "tyCanDiverge" ((PVar "tydefs") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "t")))
(DFunDef false "tyCanDiverge" (PWild PWild) (EVar "False"))
(DTypeSig false "anyTyCanDiverge" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "anyTyCanDiverge" (PWild (PList)) (EVar "False"))
(DFunDef false "anyTyCanDiverge" ((PVar "tydefs") (PCons (PVar "t") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "t")) (EApp (EApp (EVar "anyTyCanDiverge") (EVar "tydefs")) (EVar "rest"))))
(DTypeSig false "listLenMax" (TyCon "Int"))
(DFunDef false "listLenMax" () (ELit (LInt 7)))
(DTypeSig false "listLenBound" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "Int")))))
(DFunDef false "listLenBound" ((PVar "tydefs") (PVar "depth") (PVar "t")) (EIf (EBinOp "||" (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EApp (EVar "tyCanDiverge") (EVar "tydefs")) (EVar "t")))) (EVar "listLenMax") (EIf (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (ELit (LInt 0)) (EApp (EApp (EMethodRef "max") (ELit (LInt 1))) (EBinOp "-" (EVar "listLenMax") (EBinOp "*" (ELit (LInt 2)) (EVar "depth")))))))
(DTypeSig false "variantWeights" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "variantWeights" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "variantWeights" ((PVar "tydefs") (PVar "self") (PVar "depth") (PCons (PVar "v") (PVar "rest"))) (EBlock (DoLet false false (PVar "w") (EIf (EApp (EApp (EApp (EVar "variantRecursive") (EVar "tydefs")) (EVar "self")) (EVar "v")) (EIf (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (ELit (LInt 0)) (EApp (EApp (EMethodRef "max") (ELit (LInt 1))) (EBinOp "-" (EVar "recWeight0") (EVar "depth")))) (EVar "recWeight0"))) (DoExpr (EBinOp "::" (EVar "w") (EApp (EApp (EApp (EApp (EVar "variantWeights") (EVar "tydefs")) (EVar "self")) (EVar "depth")) (EVar "rest"))))))
(DTypeSig false "sumL" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "sumL" ((PList)) (ELit (LInt 0)))
(DFunDef false "sumL" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "+" (EVar "x") (EApp (EVar "sumL") (EVar "rest"))))
(DTypeSig false "allEqualInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "allEqualInts" ((PList)) (EVar "True"))
(DFunDef false "allEqualInts" ((PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "allEqualGo") (EVar "x")) (EVar "rest")))
(DTypeSig false "allEqualGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "allEqualGo" (PWild (PList)) (EVar "True"))
(DFunDef false "allEqualGo" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "allEqualGo") (EVar "x")) (EVar "rest"))))
(DTypeSig false "pickWeighted" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Variant")))))
(DFunDef false "pickWeighted" ((PCons (PVar "v") (PVar "rest")) (PCons (PVar "w") (PVar "ws")) (PVar "r")) (EIf (EBinOp "<" (EVar "r") (EVar "w")) (EVar "v") (EApp (EApp (EApp (EVar "pickWeighted") (EVar "rest")) (EVar "ws")) (EBinOp "-" (EVar "r") (EVar "w")))))
(DFunDef false "pickWeighted" ((PCons (PVar "v") PWild) (PList) PWild) (EVar "v"))
(DFunDef false "pickWeighted" ((PList) PWild PWild) (EApp (EVar "panic") (ELit (LString "prop_runner: data type with no constructors"))))
(DTypeSig false "pickVariant" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyEffect () (Some "e") (TyCon "Variant")))))))
(DFunDef false "pickVariant" ((PVar "tydefs") (PVar "self") (PVar "depth") (PVar "variants")) (EBlock (DoLet false false (PVar "ws") (EApp (EApp (EApp (EApp (EVar "variantWeights") (EVar "tydefs")) (EVar "self")) (EVar "depth")) (EVar "variants"))) (DoExpr (EIf (EApp (EVar "allEqualInts") (EVar "ws")) (EApp (EApp (EVar "nthList") (EVar "variants")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "listLen") (EVar "variants")) (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "total") (EApp (EVar "sumL") (EVar "ws"))) (DoExpr (EIf (EBinOp "<=" (EVar "total") (ELit (LInt 0))) (EApp (EApp (EVar "nthList") (EVar "variants")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "listLen") (EVar "variants")) (ELit (LInt 1))))) (EApp (EApp (EApp (EVar "pickWeighted") (EVar "variants")) (EVar "ws")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EVar "total") (ELit (LInt 1))))))))))))
(DTypeSig false "nthList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "Int") (TyVar "a"))))
(DFunDef false "nthList" ((PCons (PVar "x") PWild) (PLit (LInt 0))) (EVar "x"))
(DFunDef false "nthList" ((PCons PWild (PVar "xs")) (PVar "n")) (EApp (EApp (EVar "nthList") (EVar "xs")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))
(DFunDef false "nthList" ((PList) PWild) (EApp (EVar "panic") (ELit (LString "nthList: index out of range"))))
(DTypeSig false "shrinkValue" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "shrinkValue" ((PVar "ty") (PVar "v")) (EMatch (ETuple (EVar "ty") (EVar "v")) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "Int")))) false) (PCon "VInt" (PVar "n"))) () (EApp (EVar "shrinkInt") (EVar "n"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "Bool")))) false) (PCon "VBool" (PCon "True"))) () (EListLit (EApp (EVar "VBool") (EVar "False")))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "Bool")))) false) (PCon "VBool" (PCon "False"))) () (EListLit)) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "Float")))) false) (PCon "VFloat" (PVar "x"))) () (EIf (EBinOp "==" (EVar "x") (ELit (LFloat 0.0))) (EListLit) (EListLit (EApp (EVar "VFloat") (ELit (LFloat 0.0))) (EApp (EVar "VFloat") (EBinOp "/" (EVar "x") (ELit (LFloat 2.0))))))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "String")))) false) (PCon "VString" (PVar "s"))) () (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EListLit) (EListLit (EApp (EVar "VString") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))) (EVar "s")))))) (arm (PTuple (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "List")))) false) PWild) (PCon "VList" (PList))) () (EListLit)) (arm (PTuple (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "List")))) false) PWild) (PCon "VList" (PCons PWild (PVar "rest")))) () (EListLit (EApp (EVar "VList") (EVar "rest")))) (arm (PTuple (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Option")))) false) PWild) (PCon "VCon" (PLit (LString "None")) (PList))) () (EListLit)) (arm (PTuple (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Option")))) false) PWild) (PCon "VCon" (PLit (LString "Some")) PWild)) () (EListLit (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)))) (arm PWild () (EListLit))))
(DTypeSig false "shrinkInt" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "shrinkInt" ((PLit (LInt 0))) (EListLit))
(DFunDef false "shrinkInt" ((PVar "n")) (EBlock (DoLet false false (PVar "cands") (EListLit (ELit (LInt 0)) (EBinOp "/" (EVar "n") (ELit (LInt 2))) (EBinOp "+" (EVar "n") (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "VInt")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "n")))) (EVar "cands"))))))
(DTypeSig false "checkProp" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "checkProp" ((PVar "evalEnv") (PVar "body") (PVar "inputs")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EBinOp "++" (EVar "inputs") (EVar "evalEnv")))) (DoExpr (EMatch (EApp (EVar "force") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))) (arm (PCon "VBool" (PVar "b")) () (EVar "b")) (arm PWild () (EVar "False"))))))
(DData Public "PropOutcome" ("v") ((variant "PropPassed" (ConPos)) (variant "PropFailed" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "v"))) (TyCon "Bool")))) ())
(DTypeSig false "lineOfPropName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int"))))
(DFunDef false "lineOfPropName" ((PVar "name") (PVar "propLines")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "propLines")) (arm (PCon "Some" (PVar "l")) () (EVar "l")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "propLocPrefix" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "propLocPrefix" (PWild (PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "propLocPrefix" ((PVar "target") (PVar "line")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))))
(DTypeSig false "runProp" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runProp" ((PVar "tydefs") (PVar "evalEnv") (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "maxTests") (PVar "target") (PVar "propLines")) (EBlock (DoLet false false (PVar "line") (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "propLocPrefix") (EVar "target")) (EVar "line")))) (ELit (LString "Testing "))) (EApp (EMethodRef "display") (EApp (EVar "escStrLocal") (EVar "name")))) (ELit (LString " ... "))))) (DoLet false false (PVar "seedAtStart") (EUnOp "!" (EVar "propRngStateRef"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (ELit (LInt 1))) (arm (PCon "PropPassed") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "OK (")) (EApp (EVar "intToString") (EVar "maxTests"))) (ELit (LString " tests)"))))) (DoExpr (EVar "True")))) (arm (PCon "PropFailed" (PVar "run") (PVar "shrunk") (PVar "fuelExhausted")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAILED after ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "run")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EIf (EBinOp "==" (EVar "run") (ELit (LInt 1))) (ELit (LString " test")) (ELit (LString " tests"))))) (ELit (LString ""))))) (DoLet false false PWild (EIf (EVar "fuelExhausted") (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "  WARNING: shrink fuel exhausted after ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "shrinkFuel")))) (ELit (LString " steps; the counterexample below may not be minimal, and a shrink arm is probably cycling (see #1307).")))) (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  Seed: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "seedAtStart")))) (ELit (LString " (rerun with: medaka test --seed "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "seedAtStart")))) (ELit (LString " --filter "))) (EApp (EMethodRef "display") (EApp (EVar "escStrLocal") (EVar "name")))) (ELit (LString " <file>)"))))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  Counterexample:")))) (DoLet false false PWild (EApp (EVar "printCounterexample") (EVar "shrunk"))) (DoExpr (EVar "False"))))))))
(DFunDef false "runProp" ((PVar "tydefs") (PVar "evalEnv") PWild (PVar "maxTests") (PVar "target") (PVar "propLines")) (EVar "True"))
(DTypeSig false "findFailure" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "findFailure" ((PVar "tydefs") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run")) (EIf (EBinOp ">" (EVar "run") (EVar "maxTests")) (EVar "PropPassed") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "inputs") (EApp (EApp (EVar "genInputs") (EVar "tydefs")) (EVar "params"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailureStep") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EVar "run")) (EVar "inputs")) (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "inputs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findFailureStep" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Bool") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "findFailureStep" ((PVar "tydefs") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run") PWild (PCon "True")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EBinOp "+" (EVar "run") (ELit (LInt 1)))))
(DFunDef false "findFailureStep" (PWild (PVar "evalEnv") (PVar "params") (PVar "body") PWild (PVar "run") (PVar "inputs") (PCon "False")) (EBlock (DoLet false false (PTuple (PVar "shrunk") (PVar "fuelExhausted")) (EApp (EApp (EApp (EApp (EVar "shrinkLoop") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "inputs"))) (DoExpr (EApp (EApp (EApp (EVar "PropFailed") (EVar "run")) (EVar "shrunk")) (EVar "fuelExhausted")))))
(DTypeSig false "genInputs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genInputs" (PWild (PList)) (EListLit))
(DFunDef false "genInputs" ((PVar "tydefs") (PCons (PCon "PropParam" (PVar "x") PWild (PVar "ty")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "x") (EApp (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EListLit)) (ELit (LInt 0))) (EVar "ty"))) (EApp (EApp (EVar "genInputs") (EVar "tydefs")) (EVar "rest"))))
(DTypeSig false "printCounterexample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printCounterexample" ((PList)) (ELit LUnit))
(DFunDef false "printCounterexample" ((PCons (PTuple (PVar "x") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "ppValue") (EVar "v")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "printCounterexample") (EVar "rest")))))
(DTypeSig false "escStrLocal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStrLocal" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DTypeSig false "shrinkFuel" (TyCon "Int"))
(DFunDef false "shrinkFuel" () (ELit (LInt 10000)))
(DTypeSig false "shrinkLoop" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "Bool"))))))))
(DFunDef false "shrinkLoop" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate")) (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoopFuel") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "shrinkFuel")))
(DTypeSig false "shrinkLoopFuel" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "Bool")))))))))
(DFunDef false "shrinkLoopFuel" (PWild PWild PWild (PVar "candidate") (PLit (LInt 0))) (ETuple (EVar "candidate") (EVar "True")))
(DFunDef false "shrinkLoopFuel" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "fuel")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (ELit (LInt 0))) (arm (PCon "Some" (PVar "better")) () (EApp (EApp (EApp (EApp (EApp (EVar "shrinkLoopFuel") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "better")) (EBinOp "-" (EVar "fuel") (ELit (LInt 1))))) (arm (PCon "None") () (ETuple (EVar "candidate") (EVar "False")))))
(DTypeSig false "tryShrinkOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))))))
(DFunDef false "tryShrinkOne" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "listLen") (EVar "params"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PCon "PropParam" (PVar "x") PWild (PVar "ty")) (EApp (EApp (EVar "nthList") (EVar "params")) (EVar "i"))) (DoLet false false (PVar "currentV") (EApp (EApp (EVar "assocVal") (EVar "x")) (EVar "candidate"))) (DoLet false false (PVar "smaller") (EApp (EApp (EVar "shrinkValue") (EVar "ty")) (EVar "currentV"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findSmaller") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "x")) (EVar "smaller")) (arm (PCon "Some" (PVar "better")) () (EApp (EVar "Some") (EVar "better"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findSmaller" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
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
(DTypeSig false "filterProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "filterProps" ((PVar "decls")) (EApp (EApp (EVar "filterDecls") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "filterDecls" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterDecls" (PWild (PList)) (EListLit))
(DFunDef false "filterDecls" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "d")) (EBinOp "::" (EVar "d") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterPropsByName" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterPropsByName" ((PCon "None") (PVar "decls")) (EVar "decls"))
(DFunDef false "filterPropsByName" ((PCon "Some" (PVar "sub")) (PVar "decls")) (EApp (EApp (EVar "filterDecls") (EApp (EVar "propNameMatches") (EMethodRef "sub"))) (EVar "decls")))
(DTypeSig false "propNameMatches" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "propNameMatches" ((PVar "sub") (PCon "DProp" PWild (PVar "name") PWild PWild)) (EApp (EApp (EVar "substringMatch") (EMethodRef "sub")) (EVar "name")))
(DFunDef false "propNameMatches" (PWild PWild) (EVar "False"))
(DTypeSig true "runAllProps" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runAllProps" ((PVar "cases") (PVar "filterOpt") (PVar "target") (PVar "propLines") (PVar "evalEnv") (PVar "program")) (EBlock (DoLet false false (PVar "props") (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "program")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "props")) (EVar "True") (EBlock (DoLet false false (PVar "tydefs") (EApp (EVar "buildTyDefs") (EVar "program"))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEach") (EVar "cases")) (EVar "target")) (EVar "propLines")) (EVar "tydefs")) (EVar "evalEnv")) (EVar "props"))) (DoLet false false (PVar "nPass") (EApp (EVar "countTrue") (EVar "results"))) (DoLet false false (PVar "nFail") (EBinOp "-" (EApp (EVar "listLen") (EVar "results")) (EVar "nPass"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nPass")))) (ELit (LString " passed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nFail")))) (ELit (LString " failed"))))) (DoExpr (EBinOp "==" (EVar "nFail") (ELit (LInt 0)))))))))
(DTypeSig false "runEach" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Bool"))))))))))
(DFunDef false "runEach" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "runEach" ((PVar "cases") (PVar "target") (PVar "propLines") (PVar "tydefs") (PVar "evalEnv") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProp") (EVar "tydefs")) (EVar "evalEnv")) (EVar "p")) (EVar "cases")) (EVar "target")) (EVar "propLines")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEach") (EVar "cases")) (EVar "target")) (EVar "propLines")) (EVar "tydefs")) (EVar "evalEnv")) (EVar "rest"))))
(DTypeSig false "countTrue" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyCon "Int")))
(DFunDef false "countTrue" ((PList)) (ELit (LInt 0)))
(DFunDef false "countTrue" ((PCons (PCon "True") (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countTrue") (EVar "rest"))))
(DFunDef false "countTrue" ((PCons (PCon "False") (PVar "rest"))) (EApp (EVar "countTrue") (EVar "rest")))
(DData Public "PropResult" () ((variant "PropResult" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "String")))) ())
(DTypeSig true "propResultName" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "propResultName" ((PCon "PropResult" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "propResultPassed" (TyFun (TyCon "PropResult") (TyCon "Bool")))
(DFunDef false "propResultPassed" ((PCon "PropResult" PWild (PVar "p") PWild)) (EVar "p"))
(DTypeSig true "propResultDetail" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "propResultDetail" ((PCon "PropResult" PWild PWild (PVar "d"))) (EVar "d"))
(DTypeSig true "runAllPropsResults" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runAllPropsResults" ((PVar "cases") (PVar "filterOpt") (PVar "propLines") (PVar "evalEnv") (PVar "program")) (EBlock (DoLet false false (PVar "props") (EApp (EApp (EVar "filterPropsByName") (EVar "filterOpt")) (EApp (EVar "filterProps") (EVar "program")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "props")) (EListLit) (EBlock (DoLet false false (PVar "tydefs") (EApp (EVar "buildTyDefs") (EVar "program"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EVar "tydefs")) (EVar "evalEnv")) (EVar "props"))))))))
(DTypeSig false "runEachResult" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "PropResult")))))))))
(DFunDef false "runEachResult" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "runEachResult" ((PVar "cases") (PVar "propLines") (PVar "tydefs") (PVar "evalEnv") (PCons (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "propResultOf") (EVar "cases")) (EApp (EApp (EVar "lineOfPropName") (EVar "name")) (EVar "propLines"))) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "cases")) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EVar "tydefs")) (EVar "evalEnv")) (EVar "rest"))))
(DFunDef false "runEachResult" ((PVar "cases") (PVar "propLines") (PVar "tydefs") (PVar "evalEnv") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "runEachResult") (EVar "cases")) (EVar "propLines")) (EVar "tydefs")) (EVar "evalEnv")) (EVar "rest")))
(DTypeSig false "propResultOf" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "PropResult"))))))
(DFunDef false "propResultOf" ((PVar "cases") (PVar "_line") (PVar "name") (PCon "PropPassed")) (EApp (EApp (EApp (EVar "PropResult") (EVar "name")) (EVar "True")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "cases")))) (ELit (LString " tests passed")))))
(DFunDef false "propResultOf" ((PVar "_cases") (PVar "line") (PVar "name") (PCon "PropFailed" (PVar "run") (PVar "shrunk") (PVar "fuelExhausted"))) (EApp (EApp (EApp (EVar "PropResult") (EVar "name")) (EVar "False")) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "lineDetailPrefix") (EVar "line")) (ELit (LString "failed after ")) (EApp (EVar "intToString") (EVar "run")) (EIf (EBinOp "==" (EVar "run") (ELit (LInt 1))) (ELit (LString " test; counterexample: ")) (ELit (LString " tests; counterexample: "))) (EApp (EVar "renderCounterexample") (EVar "shrunk")) (EIf (EVar "fuelExhausted") (ELit (LString " (WARNING: shrink fuel exhausted, counterexample may not be minimal — see #1307)")) (ELit (LString "")))))))
(DTypeSig false "lineDetailPrefix" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "lineDetailPrefix" ((PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "lineDetailPrefix" ((PVar "line")) (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ": "))))
(DTypeSig false "renderCounterexample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "String")))
(DFunDef false "renderCounterexample" ((PList)) (ELit (LString "")))
(DFunDef false "renderCounterexample" ((PList (PTuple (PVar "x") (PVar "v")))) (EApp (EVar "stringConcat") (EListLit (EVar "x") (ELit (LString " = ")) (EApp (EVar "ppValue") (EVar "v")))))
(DFunDef false "renderCounterexample" ((PCons (PTuple (PVar "x") (PVar "v")) (PVar "rest"))) (EApp (EVar "stringConcat") (EListLit (EVar "x") (ELit (LString " = ")) (EApp (EVar "ppValue") (EVar "v")) (ELit (LString ", ")) (EApp (EVar "renderCounterexample") (EVar "rest")))))
(DTypeSig true "hasProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasProps" ((PVar "decls")) (EApp (EApp (EVar "anyDecl") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "anyDecl" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "anyDecl" (PWild (PList)) (EVar "False"))
(DFunDef false "anyDecl" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "p") (EVar "d")) (EApp (EApp (EVar "anyDecl") (EVar "p")) (EVar "rest"))))
