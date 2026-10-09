# META
source_lines=1631
stages=DESUGAR,MARK
# SOURCE
-- The engine-neutral property planning layer.
--
-- This module deliberately contains no evaluator Value and no emitted source.
-- It decides what a parameter type means, which declarations own its
-- constructors, and the shared order of structural shrink candidates.

import frontend.ast.{
  Decl(..),
  Ty(..),
  TyConOrigin(..),
  DataVis(..),
  Variant(..),
  Field(..),
  ConPayload(..),
  ImplMethod(..),
  sameTyConHead,
}
import types.route_key.{typeTagOf, implRouteKeyWord}
import support.ordmap.{
  OrdMap, omEmpty, omHasKey, omInsert, omKeys, omLookup, omSize
}
import support.util.{lookupAssoc, zipL}

-- Structural property generation has one engine-neutral stream. Its 31-bit
-- state advances without overflowing Int; every consumer draws one fmix32 word
-- and reduces it only after mixing. Native probes render the same constants
-- with public runtime bit operations and overflow-safe arithmetic. The
-- generated probe must not import the higher-level u32 module: that module
-- pulls ordinary stdlib instances into a scratch project that has already
-- copied the target graph.
export
structuralRngModulus : Int
structuralRngModulus = 2147483648

export
structuralRngMultiplier : Int
structuralRngMultiplier = 1103515245

export
structuralRngIncrement : Int
structuralRngIncrement = 12345

export
structuralRngMixMultiplier1 : Int
structuralRngMixMultiplier1 = 2246822507

export
structuralRngMixMultiplier2 : Int
structuralRngMixMultiplier2 = 3266489909

export
structuralRngWordModulus : Int
structuralRngWordModulus = 4294967296

export
structuralRngWordHalf : Int
structuralRngWordHalf = 65536

export
structuralRngSeed : Int -> Int
structuralRngSeed n =
  (n % structuralRngModulus + structuralRngModulus) % structuralRngModulus

export
structuralRngAdvance : Int -> Int
structuralRngAdvance state =
  (state * structuralRngMultiplier + structuralRngIncrement)
    % structuralRngModulus

structuralRngWord : Int -> Int
structuralRngWord n =
  (n % structuralRngWordModulus + structuralRngWordModulus)
    % structuralRngWordModulus

-- Multiply two words modulo 2^32 without asking the `Int` multiplier to hold
-- a 64-bit product. Each half product and the assembled low word fit in Int.
structuralRngMulWord : Int -> Int -> Int
structuralRngMulWord left right =
  let x = structuralRngWord left
  let y = structuralRngWord right
  let xLow = x % structuralRngWordHalf
  let xHigh = x / structuralRngWordHalf
  let yLow = y % structuralRngWordHalf
  let yHigh = y / structuralRngWordHalf
  let low = xLow * yLow
  let cross = xLow * yHigh + xHigh * yLow
  structuralRngWord
    (low + cross % structuralRngWordHalf * structuralRngWordHalf)

export
structuralRngMix : Int -> Int
structuralRngMix state =
  let word = structuralRngWord state
  let h1 = structuralRngWord (bitXor word (shiftRight word 16))
  let h2 = structuralRngMulWord h1 structuralRngMixMultiplier1
  let h3 = structuralRngWord (bitXor h2 (shiftRight h2 13))
  let h4 = structuralRngMulWord h3 structuralRngMixMultiplier2
  structuralRngWord (bitXor h4 (shiftRight h4 16))

export
structuralRngRange : Int -> Int -> Int -> Int
structuralRngRange word lo hi =
  let width = hi - lo + 1
  if width <= 0 then lo else lo + word % width

export
structuralRngChoose : Int -> Int -> Int
structuralRngChoose word width = if width <= 0 then 0 else word % width

-- Container candidate order is policy, not an implementation detail of an
-- engine: deletion left-to-right precedes recursive element shrinking.
export
deleteEach : List a -> List (List a)
deleteEach [] = []
deleteEach (x :: xs) = xs :: map (prepend x) (deleteEach xs)

export
prepend : a -> List a -> List a
prepend x xs = x :: xs

export
replaceEach : (a -> List a) -> List a -> List (List a)
replaceEach _ [] = []
replaceEach smaller (x :: xs) =
  map (prependBefore xs) (smaller x) ++ map (prepend x) (replaceEach smaller xs)

export
prependBefore : List a -> a -> List a
prependBefore xs x = x :: xs

-- A spelling is never an identity.  TypeKey is carried through plans and the
-- registry is indexed by the canonical type word, so left.Box and right.Box
-- cannot select each other's constructors or Arbitrary instance.
public export data TypeKey = TypeKey String TyConOrigin

export
typeKeyWord : TypeKey -> String
typeKeyWord (TypeKey n o) = typeTagOf o n

sameTypeKey : TypeKey -> TypeKey -> Bool
sameTypeKey (TypeKey n o) (TypeKey n2 o2) = sameTyConHead n o n2 o2

public export data PlanVisibility = PlanLocal | PlanPublicCtors | PlanAbstract

public export data PlanField = PlanField (Option String) Ty

-- planCtorSource is what native source needs, while planCtorRuntime is the
-- collision-mangled tag an evaluator value carries.  The current one-graph
-- builder sets both equal; paired raw/elaborated callers can preserve both.
public export data PlanCtor = PlanCtor String String (List PlanField)

public export data PlanDef =
  | PlanDef TypeKey String (List String) PlanVisibility (List PlanCtor)

public export data CustomPlan = CustomPlan TypeKey Ty String

public export data GenPlan =
  | GInt
  | GBool
  | GFloat
  | GChar
  | GString
  | GUnit
  | GList GenPlan
  | GArray GenPlan
  | GOption GenPlan
  | GResult GenPlan GenPlan
  | GTuple (List GenPlan)
  | GNominal TypeKey (List GenPlan)
  | GCustom CustomPlan

public export data PlanErrorReason =
  | PEUnboundTyVar
  | PETypeAlias
  | PEFunction
  | PEUnsupportedType
  | PEOpaqueNominal
  | PEAmbiguousNominal
  | PENoFiniteValue
  | PEUnusableArbitrary
  | PEInaccessibleConstructors

-- Keep the property and the parameter separate: request runners must turn a
-- planning failure into a per-law capability result, never an evaluator panic.
public export data PlanError = PlanError String String Ty PlanErrorReason String

export
planErrorText : PlanError -> String
planErrorText (PlanError propName name _ reason detail) =
  "property '\{propName}', parameter '\{name}' cannot be generated: \{reasonText reason}\{if detail == "" then "" else " (" ++ detail ++ ")"}"

reasonText : PlanErrorReason -> String
reasonText PEUnboundTyVar = "unbound type variable"
reasonText PETypeAlias = "unexpanded type alias"
reasonText PEFunction = "function values have no built-in generator"
reasonText PEUnsupportedType = "unsupported parameter type"
reasonText PEOpaqueNominal = "opaque nominal type"
reasonText PEAmbiguousNominal = "ambiguous unresolved nominal type"
reasonText PENoFiniteValue = "recursive type has no finite constructor"
reasonText PEUnusableArbitrary =
  "Arbitrary instance cannot be selected for this carrier"
reasonText PEInaccessibleConstructors =
  "constructors are not visible to this property"

-- One row per nominal declaration and one per Arbitrary decision.  The maps are
-- built once for the whole loaded graph, then queried by identity rather than
-- rescanning declarations for every generated value.
public export data ArbPlan = ArbPlan Ty String
public export data PlanEnv =
  | PlanEnv String (OrdMap (List PlanDef)) (OrdMap (List ArbPlan)) (OrdMap Unit) (OrdMap Unit)

-- A source module is carried beside its elaborated/mangled counterpart.  The
-- former supplies a constructor spelling which can be imported into a native
-- probe; the latter supplies resolved TypeKey identities and the evaluator's
-- runtime constructor tag.  Reversing a private mangle is unsound, so this
-- pair is the only supported bridge.
public export data PlanModule = PlanModule String (List Decl) (List Decl)

emptyPlanEnv : PlanEnv
emptyPlanEnv = PlanEnv "" omEmpty omEmpty omEmpty omEmpty

export
buildPlanEnv : List Decl -> PlanEnv
buildPlanEnv decls = buildPlanEnvGo decls emptyPlanEnv

-- Preferred entry point for multi-module tests. It collects every resolved
-- declaration (including Arbitrary instances), then replaces nominal rows
-- with source/runtime constructor pairs.
export
buildPlanEnvModules : String -> List PlanModule -> Result PlanError PlanEnv
buildPlanEnvModules root modules =
  pairModules modules (PlanEnv root omEmpty omEmpty omEmpty omEmpty)

pairModules : List PlanModule -> PlanEnv -> Result PlanError PlanEnv
pairModules [] env = Ok env
pairModules ((PlanModule mid raw runtime) :: rest) env =
  match pairModuleDecls mid raw runtime env
    Ok env2 => pairModules rest env2
    Err e => Err e

pairModuleDecls : String ->
  List Decl ->
  List Decl ->
  PlanEnv ->
  Result PlanError PlanEnv
pairModuleDecls mid raw runtime env =
  if rawNominalsPresent raw runtime then
    pairRuntimeDecls mid (rawNominalMap raw omEmpty) runtime env
  else
    Err (pairError "raw nominal declaration has no runtime counterpart")

rawNominalsPresent : List Decl -> List Decl -> Bool
rawNominalsPresent [] _ = True
rawNominalsPresent ((DAttrib _ d) :: rest) runtime =
  rawNominalsPresent (d :: rest) runtime
rawNominalsPresent ((DData { dataName = name }) :: rest) runtime =
  runtimeHasNominal name runtime && rawNominalsPresent rest runtime
rawNominalsPresent ((DNewtype { newtypeName = name }) :: rest) runtime =
  runtimeHasNominal name runtime && rawNominalsPresent rest runtime
rawNominalsPresent (_ :: rest) runtime = rawNominalsPresent rest runtime

runtimeHasNominal : String -> List Decl -> Bool
runtimeHasNominal _ [] = False
runtimeHasNominal name ((DAttrib _ d) :: rest) =
  runtimeHasNominal name (d :: rest)
runtimeHasNominal name ((DData { dataName = actual }) :: rest) =
  name == actual || runtimeHasNominal name rest
runtimeHasNominal name ((DNewtype { newtypeName = actual }) :: rest) =
  name == actual || runtimeHasNominal name rest
runtimeHasNominal name (_ :: rest) = runtimeHasNominal name rest

-- Elaboration may insert derives and other declarations, so the two streams
-- cannot be zipped. Index only raw nominal declarations by source type name,
-- then join each resolved nominal inside its module. Variant positions are
-- paired only after that declaration identity has matched.
rawNominalMap : List Decl -> OrdMap Decl -> OrdMap Decl
rawNominalMap [] acc = acc
rawNominalMap ((DAttrib _ d) :: rest) acc = rawNominalMap (d :: rest) acc
rawNominalMap ((d@(DData { dataName = name })) :: rest) acc =
  rawNominalMap rest (omInsert name d acc)
rawNominalMap ((d@(DNewtype { newtypeName = name })) :: rest) acc =
  rawNominalMap rest (omInsert name d acc)
rawNominalMap (_ :: rest) acc = rawNominalMap rest acc

pairRuntimeDecls : String ->
  OrdMap Decl ->
  List Decl ->
  PlanEnv ->
  Result PlanError PlanEnv
pairRuntimeDecls _ _ [] env = Ok env
pairRuntimeDecls mid rawMap (runtime :: rest) env =
  match pairRuntimeDecl mid rawMap runtime env
    Ok env2 => pairRuntimeDecls mid rawMap rest env2
    Err e => Err e

pairRuntimeDecl : String ->
  OrdMap Decl ->
  Decl ->
  PlanEnv ->
  Result PlanError PlanEnv
pairRuntimeDecl mid rawMap (DAttrib _ d) env = pairRuntimeDecl mid rawMap d env
pairRuntimeDecl mid rawMap (runtime@(DData { dataName = name })) env =
  match omLookup name rawMap
    Some raw => pairPlanDecl mid raw runtime env
    None =>
      Err (pairError ("runtime data '" ++ name ++ "' has no raw declaration"))
pairRuntimeDecl mid rawMap (runtime@(DNewtype { newtypeName = name })) env =
  match omLookup name rawMap
    Some raw => pairPlanDecl mid raw runtime env
    None =>
      Err
        (pairError ("runtime newtype '" ++ name ++ "' has no raw declaration"))
pairRuntimeDecl _ _ runtime env = Ok (addPlanDeclRuntimeOnly runtime env)

addPlanDeclRuntimeOnly : Decl -> PlanEnv -> PlanEnv
addPlanDeclRuntimeOnly runtime env = addPlanDecl runtime env

pairError : String -> PlanError
pairError detail = PlanError "" "" (TyVar "") PEUnsupportedType detail

pairPlanDecl : String -> Decl -> Decl -> PlanEnv -> Result PlanError PlanEnv
pairPlanDecl mid (DAttrib _ raw) (DAttrib _ runtime) env =
  pairPlanDecl mid raw runtime env
pairPlanDecl mid (DData { dataName = rawName, dataCtors = rawCtors }) (DData { dataName = runtimeName, dataParams = ps, dataCtors = runtimeCtors, dataVis = vis, dataOrigin = o }) env
  | rawName == runtimeName =
    let key = TypeKey runtimeName o
    map
      (ctors =>
        insertDef (PlanDef key (ownerOf o) ps (visibilityOf vis) ctors) env)
      (pairCtors rawCtors runtimeCtors)
pairPlanDecl mid (DNewtype { newtypeName = rawName, newtypeCtor = rawCtor }) (DNewtype { newtypeName = runtimeName, newtypeParams = ps, newtypeCtor = runtimeCtor, newtypeFieldTy = fieldTy, newtypePub = pub, newtypeOrigin = o }) env
  | rawName == runtimeName =
    let key = TypeKey runtimeName o
    let def = PlanDef key (ownerOf o) ps (newtypeVisibility pub) [
      PlanCtor rawCtor runtimeCtor [PlanField None fieldTy],
    ]
    Ok (insertDef def env)
pairPlanDecl _ _ _ _ =
  Err (pairError "raw and runtime nominal declarations disagree")

pairCtors : List Variant -> List Variant -> Result PlanError (List PlanCtor)
pairCtors [] [] = Ok []
pairCtors [] _ = Err (pairError "raw/runtime constructor counts disagree")
pairCtors _ [] = Err (pairError "raw/runtime constructor counts disagree")
pairCtors ((Variant rawName rawPayload) :: raws) ((Variant runtimeName runtimePayload) :: runtimes) =
  match (pairFields rawPayload runtimePayload, pairCtors raws runtimes)
    (Ok fields, Ok rest) => Ok (PlanCtor rawName runtimeName fields :: rest)
    (Err e, _) => Err e
    (_, Err e) => Err e

pairFields : ConPayload -> ConPayload -> Result PlanError (List PlanField)
pairFields (ConPos rawTys) (ConPos runtimeTys)
  | listLength rawTys == listLength runtimeTys =
    Ok (map (t => PlanField None t) runtimeTys)
pairFields (ConNamed rawFields _) (ConNamed runtimeFields _) =
  pairNamedFields rawFields runtimeFields
pairFields _ _ = Err (pairError "raw/runtime constructor payloads disagree")

pairNamedFields : List Field -> List Field -> Result PlanError (List PlanField)
pairNamedFields [] [] = Ok []
pairNamedFields [] _ = Err (pairError "raw/runtime named field counts disagree")
pairNamedFields _ [] = Err (pairError "raw/runtime named field counts disagree")
pairNamedFields ((Field rawName _) :: raws) ((Field runtimeName runtimeTy) :: runtimes)
  | rawName == runtimeName =
    map
      (PlanField (Some rawName) runtimeTy :: _)
      (pairNamedFields raws runtimes)
pairNamedFields _ _ = Err (pairError "raw/runtime named field names disagree")

listLength : List a -> Int
listLength [] = 0
listLength (_ :: xs) = 1 + listLength xs

buildPlanEnvGo : List Decl -> PlanEnv -> PlanEnv
buildPlanEnvGo [] env = env
buildPlanEnvGo (d :: rest) env = buildPlanEnvGo rest (addPlanDecl d env)

addPlanDecl : Decl -> PlanEnv -> PlanEnv
addPlanDecl (DAttrib _ d) env = addPlanDecl d env
addPlanDecl (DData { dataName = n, dataParams = ps, dataCtors = cs, dataVis = vis, dataOrigin = o }) env =
  let key = TypeKey n o
  let def = PlanDef key (ownerOf o) ps (visibilityOf vis) (map ctorOfVariant cs)
  insertDef def env
addPlanDecl (DNewtype { newtypeName = n, newtypeParams = ps, newtypeCtor = c, newtypeFieldTy = t, newtypePub = pub, newtypeOrigin = o }) env =
  let key = TypeKey n o
  let def = PlanDef key (ownerOf o) ps (newtypeVisibility pub) [
    PlanCtor c c [PlanField None t],
  ]
  insertDef def env
addPlanDecl (DTypeAlias { tyAliasName = n, tyAliasOrigin = o }) (PlanEnv root defs arbs bad aliases) =
  PlanEnv root defs arbs bad (omInsert (typeTagOf o n) () aliases)
addPlanDecl d env = addArbitrary d env

visibilityOf : DataVis -> PlanVisibility
visibilityOf VisPrivate = PlanLocal
visibilityOf VisPublic = PlanPublicCtors
visibilityOf VisAbstract = PlanAbstract

newtypeVisibility : Bool -> PlanVisibility
newtypeVisibility _ = PlanLocal

ownerOf : TyConOrigin -> String
ownerOf (OriginModule m) = m
ownerOf _ = ""

ctorOfVariant : Variant -> PlanCtor
ctorOfVariant (Variant c (ConPos ts)) =
  PlanCtor c c (map (t => PlanField None t) ts)
ctorOfVariant (Variant c (ConNamed fs _)) = PlanCtor c c (map namedField fs)

namedField : Field -> PlanField
namedField (Field n t) = PlanField (Some n) t

addArbitrary : Decl -> PlanEnv -> PlanEnv
addArbitrary (DAttrib _ d) env = addArbitrary d env
addArbitrary (DImpl { iface = "Arbitrary", implOrigin = (OriginModule "core"), tys = [carrier] }) env =
  insertArb (ArbPlan carrier (arbCarrierWord carrier)) env
addArbitrary _ env = env

arbCarrierWord : Ty -> String
arbCarrierWord ty = implRouteKeyWord (OriginModule "core") "Arbitrary" [ty] None

insertDef : PlanDef -> PlanEnv -> PlanEnv
insertDef (def@(PlanDef key _ _ _ _)) (PlanEnv root defs arbs bad aliases) =
  let word = typeKeyWord key
  let prior = optionList (omLookup word defs)
  PlanEnv root (omInsert word (def :: prior) defs) arbs bad aliases

insertArb : ArbPlan -> PlanEnv -> PlanEnv
insertArb (arb@(ArbPlan carrier _)) (PlanEnv root defs arbs bad aliases) =
  match headKey carrier
    Some key =>
      let word = typeKeyWord key
      let prior = optionList (omLookup word arbs)
      PlanEnv root defs (omInsert word (arb :: prior) arbs) bad aliases
    None => PlanEnv root defs arbs bad aliases

optionList : Option (List a) -> List a
optionList None = []
optionList (Some xs) = xs

-- A type is built from references, never recursively expanded.  That keeps
-- mutually recursive declarations finite in the plan itself.
planForGo : PlanEnv -> String -> String -> Ty -> Result PlanError GenPlan
planForGo _ propName param (ty@(TyVar _)) =
  Err (PlanError propName param ty PEUnboundTyVar "")
planForGo _ _ _ (TyCon { tyConName = "Int", tyConOrigin = OriginBuiltin }) =
  Ok GInt
planForGo _ _ _ (TyCon { tyConName = "Bool", tyConOrigin = OriginBuiltin }) =
  Ok GBool
planForGo _ _ _ (TyCon { tyConName = "Float", tyConOrigin = OriginBuiltin }) =
  Ok GFloat
planForGo _ _ _ (TyCon { tyConName = "Char", tyConOrigin = OriginBuiltin }) =
  Ok GChar
planForGo _ _ _ (TyCon { tyConName = "String", tyConOrigin = OriginBuiltin }) =
  Ok GString
planForGo _ _ _ (TyCon { tyConName = "Unit", tyConOrigin = OriginBuiltin }) =
  Ok GUnit
planForGo env propName param (TyApp (TyCon { tyConName = "List", tyConOrigin = o }) t)
  | builtinOrigin o = map GList (planForGo env propName param t)
planForGo env propName param (TyApp (TyCon { tyConName = "Array", tyConOrigin = o }) t)
  | builtinOrigin o = map GArray (planForGo env propName param t)
planForGo env propName param (TyApp (TyCon { tyConName = "Option", tyConOrigin = o }) t)
  | builtinOrigin o = map GOption (planForGo env propName param t)
planForGo env propName param (TyApp (TyApp (TyCon { tyConName = "Result", tyConOrigin = o }) e) a)
  | builtinOrigin o =
    map2
      GResult
      (planForGo env propName param e)
      (planForGo env propName param a)
planForGo env propName param ty
  | builtinTupleSpine ty =
    map GTuple (planMany env propName param (planArgs ty))
planForGo env propName param (TyTuple ts) =
  map GTuple (planMany env propName param ts)
planForGo _ propName param (ty@(TyFun _ _)) =
  Err (PlanError propName param ty PEFunction "")
planForGo env propName param (TyNamed _ t _) = planForGo env propName param t
planForGo env propName param (TyQual t _ _) = planForGo env propName param t
planForGo env propName param (TyConstrained _ t) =
  planForGo env propName param t
planForGo env propName param ty = match headKey ty
  None => Err (PlanError propName param ty PEUnsupportedType "")
  Some key => planNominal env propName param key (planArgs ty)

builtinOrigin : TyConOrigin -> Bool
builtinOrigin OriginBuiltin = True
builtinOrigin (OriginModule "core") = True
builtinOrigin _ = False

-- Resolved tuples are saturated `__tupleN__` application spines, while a few
-- raw AST callers still use `TyTuple`. The built-in origin and exact arity
-- keep a user spelling of the synthetic name from becoming a tuple.
builtinTupleSpine : Ty -> Bool
builtinTupleSpine ty = match headKey ty
  Some (TypeKey "__tuple2__" OriginBuiltin) => listLength (planArgs ty) == 2
  Some (TypeKey "__tuple3__" OriginBuiltin) => listLength (planArgs ty) == 3
  Some (TypeKey "__tuple4__" OriginBuiltin) => listLength (planArgs ty) == 4
  Some (TypeKey "__tuple5__" OriginBuiltin) => listLength (planArgs ty) == 5
  _ => False

headKey : Ty -> Option TypeKey
headKey (TyCon { tyConName = n, tyConOrigin = o }) = Some (TypeKey n o)
headKey (TyApp f _) = headKey f
headKey _ = None

planArgs : Ty -> List Ty
planArgs t = planArgsGo [] t

planArgsGo : List Ty -> Ty -> List Ty
planArgsGo acc (TyApp f a) = planArgsGo (a :: acc) f
planArgsGo acc _ = acc

planNominal : PlanEnv ->
  String ->
  String ->
  TypeKey ->
  List Ty ->
  Result PlanError GenPlan
planNominal (PlanEnv root defs arbs bad aliases) propName param key args =
  let carrier = rebuildTy key args
  match (selectedCustom
    key
    carrier
    (optionList (omLookup (typeKeyWord key) arbs)))
    Err detail =>
      Err (PlanError propName param carrier PEUnusableArbitrary detail)
    Ok (Some custom) => Ok (GCustom custom)
    Ok None =>
      match matchingDef key (optionList (omLookup (typeKeyWord key) defs))
        None if isSome (omLookup (typeKeyWord key) aliases) =>
          Err (PlanError propName param (rebuildTy key args) PETypeAlias "")
        None if hasAmbiguousUnresolved
          key
          (optionList (omLookup (typeKeyWord key) defs)) =>
          Err
            (PlanError
              propName
              param
              (rebuildTy key args)
              PEAmbiguousNominal
              "")
        None =>
          Err
            (PlanError
              propName
              param
              (rebuildTy key args)
              PEOpaqueNominal
              "no visible data declaration")
        Some (PlanDef _ owner _ PlanAbstract _) if owner /= root =>
          Err (PlanError propName param (rebuildTy key args) PEOpaqueNominal "")
        Some (PlanDef _ owner _ PlanLocal _) if owner /= root =>
          Err
            (PlanError
              propName
              param
              (rebuildTy key args)
              PEInaccessibleConstructors
              "")
        Some (PlanDef _ _ _ _ []) =>
          Err
            (PlanError
              propName
              param
              (rebuildTy key args)
              PENoFiniteValue
              "no constructors")
        Some (PlanDef _ _ _ _ _) =>
          map
            (GNominal key)
            (planMany (PlanEnv root defs arbs bad aliases) propName param args)

-- A concrete carrier must win over a generic one.  Generic rows are only a
-- selection hint here: the typed helper binding performs ordinary instance
-- resolution (including required dictionaries) before the evaluator runs it.
-- That keeps planner matching identity-aware without duplicating typeclass
-- entailment or choosing a method by declaration order.
selectedCustom : TypeKey ->
  Ty ->
  List ArbPlan ->
  Result String (Option CustomPlan)
selectedCustom key carrier candidates = match exactArbs carrier candidates
  [] => match matchingArbs carrier candidates
    [] => Ok None
    _ => Ok (Some (CustomPlan key carrier (arbCarrierWord carrier)))
  [_] => Ok (Some (CustomPlan key carrier (arbCarrierWord carrier)))
  _ => Err "multiple exact Arbitrary instances select this carrier"

exactArbs : Ty -> List ArbPlan -> List ArbPlan
exactArbs _ [] = []
exactArbs carrier ((arb@(ArbPlan pattern _)) :: rest)
  | arbCarrierWord pattern == arbCarrierWord carrier =
    arb :: exactArbs carrier rest
  | otherwise = exactArbs carrier rest

matchingArbs : Ty -> List ArbPlan -> List ArbPlan
matchingArbs _ [] = []
matchingArbs carrier ((arb@(ArbPlan pattern _)) :: rest) =
  match matchArbCarrier pattern carrier omEmpty
    Some _ => arb :: matchingArbs carrier rest
    None => matchingArbs carrier rest

-- Bind each pattern variable once and compare every concrete head through the
-- compiler's canonical route word.  This accepts `Tree a` for `Tree Int` and
-- rejects `Pair a a` for `Pair Int Bool`; it never confuses same-spelled
-- nominal heads from separate modules.
matchArbCarrier : Ty -> Ty -> OrdMap Ty -> Option (OrdMap Ty)
matchArbCarrier (TyVar name) actual bindings = match omLookup name bindings
  Some bound =>
    if arbCarrierWord bound == arbCarrierWord actual then
      Some bindings
    else
      None
  None => Some (omInsert name actual bindings)
matchArbCarrier (TyApp pf pa) (TyApp af aa) bindings =
  match matchArbCarrier pf af bindings
    Some next => matchArbCarrier pa aa next
    None => None
matchArbCarrier (TyTuple ps) (TyTuple actuals) bindings =
  matchArbCarriers ps actuals bindings
matchArbCarrier pattern actual bindings =
  if arbCarrierWord pattern == arbCarrierWord actual then
    Some bindings
  else
    None

matchArbCarriers : List Ty -> List Ty -> OrdMap Ty -> Option (OrdMap Ty)
matchArbCarriers [] [] bindings = Some bindings
matchArbCarriers (p :: ps) (a :: restActuals) bindings =
  match matchArbCarrier p a bindings
    Some next => matchArbCarriers ps restActuals next
    None => None
matchArbCarriers _ _ _ = None

matchingDef : TypeKey -> List PlanDef -> Option PlanDef
matchingDef _ [] = None
matchingDef key ((d@(PlanDef actual _ _ _ _)) :: rest) =
  if sameTypeKey key actual then Some d else matchingDef key rest

hasAmbiguousUnresolved : TypeKey -> List PlanDef -> Bool
hasAmbiguousUnresolved (TypeKey n OriginUnresolved) defs = listLength defs > 1
hasAmbiguousUnresolved _ _ = False

rebuildTy : TypeKey -> List Ty -> Ty
rebuildTy (TypeKey n o) args =
  foldTy TyCon { tyConName = n, tyConLoc = None, tyConOrigin = o } args

foldTy : Ty -> List Ty -> Ty
foldTy t [] = t
foldTy t (a :: rest) = foldTy (TyApp t a) rest

planMany : PlanEnv ->
  String ->
  String ->
  List Ty ->
  Result PlanError (List GenPlan)
planMany _ _ _ [] = Ok []
planMany env propName param (t :: rest) = match (
  planForGo env propName param t,
  planMany env propName param rest,
)
  (Ok p, Ok ps) => Ok (p :: ps)
  (Err e, _) => Err e
  (_, Err e) => Err e

export
planDef : PlanEnv -> TypeKey -> Result PlanError PlanDef
planDef (PlanEnv _ defs _ _ _) key =
  match matchingDef key (optionList (omLookup (typeKeyWord key) defs))
    Some d => Ok d
    None => Err (PlanError "" "" (rebuildTy key []) PEAmbiguousNominal "")

-- Instantiate a selected constructor's fields with a nominal plan's arguments.
-- Field names remain attached, so record and positional constructors are not
-- conflated by a renderer.
export
instantiateCtor : PlanEnv ->
  GenPlan ->
  PlanCtor ->
  Result PlanError (List (Option String, GenPlan))
instantiateCtor env (GNominal key args) (PlanCtor _ _ fields) =
  match planDef env key
    Ok (PlanDef _ _ params _ _) => instantiateFields env params args fields
    Err e => Err e
instantiateCtor _ p _ =
  Err
    (PlanError
      ""
      ""
      (TyVar "")
      PEUnsupportedType
      ("not nominal: " ++ planKind p))

-- A property can reach a custom carrier through fields of a structural nominal
-- plan.  Walk those instantiated fields as well as explicit parameter plans,
-- stopping at the full carrier identity so recursive declarations remain
-- finite.  The identity includes every applied argument and nominal origin;
-- it is the same route word used for the typed helper registry.
export
customPlansReachable : PlanEnv -> List GenPlan -> List CustomPlan
customPlansReachable env plans =
  reverseCustomPlans (customPlansGo env plans omEmpty [])

reverseCustomPlans : List CustomPlan -> List CustomPlan
reverseCustomPlans plans = reverseCustomPlansGo plans []

reverseCustomPlansGo : List CustomPlan -> List CustomPlan -> List CustomPlan
reverseCustomPlansGo [] acc = acc
reverseCustomPlansGo (plan :: rest) acc =
  reverseCustomPlansGo rest (plan :: acc)

customPlansGo : PlanEnv ->
  List GenPlan ->
  OrdMap Unit ->
  List CustomPlan ->
  List CustomPlan
customPlansGo _ [] _ found = found
customPlansGo env (plan :: rest) seen found =
  let (seen2, found2) = customPlansIn env 0 plan seen found
  customPlansGo env rest seen2 found2

customPlansIn : PlanEnv ->
  Int ->
  GenPlan ->
  OrdMap Unit ->
  List CustomPlan ->
  (OrdMap Unit, List CustomPlan)
customPlansIn env depth plan seen found =
  let word = arbCarrierWord (planTy plan)
  if omHasKey word seen then
    (seen, found)
  else
    let visited = omInsert word () seen
    match plan
      GCustom custom => (visited, custom :: found)
      GList item => customPlansIn env depth item visited found
      GArray item => customPlansIn env depth item visited found
      GOption item => customPlansIn env depth item visited found
      GResult err ok =>
        let (afterErr, foundErr) = customPlansIn env depth err visited found
        customPlansIn env depth ok afterErr foundErr
      GTuple items => customPlansState env depth items visited found
      nominal@(GNominal key _) => match planDef env key
        Ok (PlanDef _ _ _ _ ctors) =>
          customPlansCtors
            env
            (depth + 1)
            nominal
            ctors
            (ctorWeights env nominal depth)
            visited
            found
        Err _ => (visited, found)
      _ => (visited, found)

customPlansState : PlanEnv ->
  Int ->
  List GenPlan ->
  OrdMap Unit ->
  List CustomPlan ->
  (OrdMap Unit, List CustomPlan)
customPlansState _ _ [] seen found = (seen, found)
customPlansState env depth (plan :: rest) seen found =
  let (seen2, found2) = customPlansIn env depth plan seen found
  customPlansState env depth rest seen2 found2

customPlansCtors : PlanEnv ->
  Int ->
  GenPlan ->
  List PlanCtor ->
  List Int ->
  OrdMap Unit ->
  List CustomPlan ->
  (OrdMap Unit, List CustomPlan)
customPlansCtors _ _ _ [] _ seen found = (seen, found)
customPlansCtors _ _ _ _ [] seen found = (seen, found)
customPlansCtors env depth nominal (ctor :: rest) (weight :: weights) seen found =
  if weight <= 0 then
    customPlansCtors env depth nominal rest weights seen found
  else match instantiateCtor env nominal ctor
    Ok fields =>
      let (seen2, found2) = customPlansFields env depth fields seen found
      customPlansCtors env depth nominal rest weights seen2 found2
    Err _ => customPlansCtors env depth nominal rest weights seen found

customPlansFields : PlanEnv ->
  Int ->
  List (Option String, GenPlan) ->
  OrdMap Unit ->
  List CustomPlan ->
  (OrdMap Unit, List CustomPlan)
customPlansFields _ _ [] seen found = (seen, found)
customPlansFields env depth ((_, plan) :: rest) seen found =
  let (seen2, found2) = customPlansIn env depth plan seen found
  customPlansFields env depth rest seen2 found2

planKind : GenPlan -> String
planKind GInt = "Int"
planKind GBool = "Bool"
planKind GFloat = "Float"
planKind GChar = "Char"
planKind GString = "String"
planKind GUnit = "Unit"
planKind _ = "compound"

instantiateFields : PlanEnv ->
  List String ->
  List GenPlan ->
  List PlanField ->
  Result PlanError (List (Option String, GenPlan))
instantiateFields _ _ _ [] = Ok []
instantiateFields env params args ((PlanField name ty) :: rest) = match (
  planTyWithPlans env "" (zipL params args) ty,
  instantiateFields env params args rest,
)
  (Ok p, Ok ps) => Ok ((name, p) :: ps)
  (Err e, _) => Err e
  (_, Err e) => Err e

planTyWithPlans : PlanEnv ->
  String ->
  List (String, GenPlan) ->
  Ty ->
  Result PlanError GenPlan
planTyWithPlans _ param subst (TyVar n) = match lookupAssoc n subst
  Some p => Ok p
  None => Err (PlanError "" param (TyVar n) PEUnboundTyVar "")
planTyWithPlans env param subst (TyApp a b) =
  planForGo env "" param (substTy subst (TyApp a b))
planTyWithPlans env param subst (TyTuple ts) =
  map GTuple (planManySubst env param subst ts)
planTyWithPlans env param subst t = planForGo env "" param (substTy subst t)

planManySubst : PlanEnv ->
  String ->
  List (String, GenPlan) ->
  List Ty ->
  Result PlanError (List GenPlan)
planManySubst _ _ _ [] = Ok []
planManySubst env param subst (t :: rest) = match (
  planTyWithPlans env param subst t,
  planManySubst env param subst rest,
)
  (Ok p, Ok ps) => Ok (p :: ps)
  (Err e, _) => Err e
  (_, Err e) => Err e

substTy : List (String, GenPlan) -> Ty -> Ty
substTy subst t = substTyRaw (map planSubstPair subst) t

planSubstPair : (String, GenPlan) -> (String, Ty)
planSubstPair (n, p) = (n, planTy p)

-- This is also the evaluator adapter's plain type substitution.  Keeping it
-- here prevents a second, almost-identical recursive implementation from
-- silently missing a new Ty constructor.
export
substTyRaw : List (String, Ty) -> Ty -> Ty
substTyRaw subst (TyVar n) = match lookupAssoc n subst
  Some t => t
  None => TyVar n
substTyRaw subst (TyApp a b) = TyApp (substTyRaw subst a) (substTyRaw subst b)
substTyRaw subst (TyTuple ts) = TyTuple (map (substTyRaw subst) ts)
substTyRaw subst (TyFun a b) = TyFun (substTyRaw subst a) (substTyRaw subst b)
substTyRaw subst (TyEffect es tail t) = TyEffect es tail (substTyRaw subst t)
substTyRaw subst (TyNamed n t dom) = TyNamed n (substTyRaw subst t) dom
substTyRaw subst (TyQual t qs loc) = TyQual (substTyRaw subst t) qs loc
substTyRaw subst (TyConstrained cs t) = TyConstrained cs (substTyRaw subst t)
substTyRaw _ t = t

export
planTy : GenPlan -> Ty
planTy GInt = builtinTy "Int"
planTy GBool = builtinTy "Bool"
planTy GFloat = builtinTy "Float"
planTy GChar = builtinTy "Char"
planTy GString = builtinTy "String"
planTy GUnit = builtinTy "Unit"
planTy (GList p) = TyApp (builtinTy "List") (planTy p)
planTy (GArray p) = TyApp (builtinTy "Array") (planTy p)
planTy (GOption p) = TyApp (builtinTy "Option") (planTy p)
planTy (GResult e a) = TyApp (TyApp (builtinTy "Result") (planTy e)) (planTy a)
planTy (GTuple ps) = TyTuple (map planTy ps)
planTy (GNominal (TypeKey n o) ps) =
  foldTy
    TyCon { tyConName = n, tyConLoc = None, tyConOrigin = o }
    (map planTy ps)
planTy (GCustom (CustomPlan _ carrier _)) = carrier

builtinTy : String -> Ty
builtinTy n =
  TyCon { tyConName = n, tyConLoc = None, tyConOrigin = OriginBuiltin }

-- Shared generation policy constants.  Renderers consume these values, not a
-- private smaller domain.
export
intMin : Int
intMin = -1000
export
intMax : Int
intMax = 1000
export
charMin : Int
charMin = 32
export
charMax : Int
charMax = 126
export
stringMaxLength : Int
stringMaxLength = 10
export
listLenMax : Int
listLenMax = 7
export
recWeight0 : Int
recWeight0 = 6
export
maxGenDepth : Int
maxGenDepth = 24

-- The adapters receive these decisions as data.  A plan is already instantiated
-- here, so generic arguments and mutually-recursive declarations cannot drift
-- between the evaluator and native renderers.
export
ctorWeights : PlanEnv -> GenPlan -> Int -> List Int
ctorWeights env (nominal@(GNominal _ _)) depth = match nominalCtors env nominal
  Ok (PlanDef _ _ _ _ ctors) =>
    if depth >= maxGenDepth then
      map (boundCtorWeight env nominal) ctors
    else
      map (softCtorWeight env nominal depth) ctors
  Err _ => []
ctorWeights _ _ _ = []

nominalCtors : PlanEnv -> GenPlan -> Result PlanError PlanDef
nominalCtors env (GNominal key _) = planDef env key
nominalCtors _ plan =
  Err (PlanError "" "" (planTy plan) PEUnsupportedType "not a nominal plan")

-- Below `maxGenDepth` a constructor weight is either a constant or decays with
-- depth.  The native renderer emits the decaying form as an expression over the
-- runtime depth, so this one shape is what both engines evaluate.
public export data SoftWeight = SoftNever | SoftFixed Int | SoftDecaying Int

export
softCtorWeights : PlanEnv -> GenPlan -> List SoftWeight
softCtorWeights env (nominal@(GNominal _ _)) = match nominalCtors env nominal
  Ok (PlanDef _ _ _ _ ctors) => map (softCtorWeightForm env nominal) ctors
  Err _ => []
softCtorWeights _ _ = []

softWeightAt : Int -> SoftWeight -> Int
softWeightAt _ SoftNever = 0
softWeightAt _ (SoftFixed weight) = weight
softWeightAt depth (SoftDecaying start) = max 1 (start - depth)

softCtorWeightForm : PlanEnv -> GenPlan -> PlanCtor -> SoftWeight
softCtorWeightForm env nominal ctor =
  if not (ctorHasFiniteFields env nominal ctor) then
    SoftNever
  else if ctorCanDiverge env nominal ctor then
    SoftDecaying recWeight0
  else
    SoftFixed recWeight0

softCtorWeight : PlanEnv -> GenPlan -> Int -> PlanCtor -> Int
softCtorWeight env nominal depth ctor =
  softWeightAt depth (softCtorWeightForm env nominal ctor)

ctorHasFiniteFields : PlanEnv -> GenPlan -> PlanCtor -> Bool
ctorHasFiniteFields env nominal ctor = match instantiateCtor env nominal ctor
  Ok fields => allPlansFinite env (fieldPlansOnly fields)
  Err _ => False

ctorCanDiverge : PlanEnv -> GenPlan -> PlanCtor -> Bool
ctorCanDiverge env nominal ctor = match instantiateCtor env nominal ctor
  Ok fields => anyPlanDiverges env (fieldPlansOnly fields)
  Err _ => False

-- At the bound every chosen nominal constructor must lower its finite-height
-- witness. Container plans contribute their empty/none witness, and their own
-- branch weights below prevent that witness from being bypassed at runtime.
boundCtorWeight : PlanEnv -> GenPlan -> PlanCtor -> Int
boundCtorWeight env nominal ctor =
  if ctorLowersFiniteHeight env nominal ctor then 1 else 0

ctorLowersFiniteHeight : PlanEnv -> GenPlan -> PlanCtor -> Bool
ctorLowersFiniteHeight env nominal ctor = match (
  planFiniteHeight env nominal [],
  instantiateCtor env nominal ctor,
)
  (Some height, Ok fields) => allPlansBelow env height (fieldPlansOnly fields)
  _ => False

planHasFiniteValue : PlanEnv -> GenPlan -> Bool
planHasFiniteValue env plan = abstractFinite env (finiteTruth env plan) plan

-- Finite search is bounded by the reachable abstract carrier space. A nominal
-- carrier consists of its declaration identity and one finite/non-finite bit
-- per instantiated argument. A shortest finite constructor path cannot repeat
-- one of those states. Concrete argument heights are added separately, so
-- `Box (Box (Box Int))` keeps its three real wrapper layers while `Rotate`
-- may change parameter positions until a container supplies an empty value.
planFiniteHeight : PlanEnv -> GenPlan -> List TypeKey -> Option Int
planFiniteHeight env plan _ =
  let truth = finiteTruth env plan
  if abstractFinite env truth plan then
    findFiniteHeight env plan 0 (finiteHeightLimit env truth plan)
  else
    None

finiteHeightLimit : PlanEnv -> OrdMap Unit -> GenPlan -> Int
finiteHeightLimit env truth (nominal@(GNominal _ args)) =
  max
    1
    (omSize (reachableStates env truth nominal) + greatestWitnessBound env args)
finiteHeightLimit _ _ GInt = 0
finiteHeightLimit _ _ GBool = 0
finiteHeightLimit _ _ GFloat = 0
finiteHeightLimit _ _ GChar = 0
finiteHeightLimit _ _ GString = 0
finiteHeightLimit _ _ GUnit = 0
finiteHeightLimit _ _ (GList _) = 0
finiteHeightLimit _ _ (GArray _) = 0
finiteHeightLimit _ _ (GOption _) = 0
finiteHeightLimit env _ (GResult err ok) =
  max (witnessBound env err) (witnessBound env ok)
finiteHeightLimit env _ (GTuple plans) = greatestWitnessBound env plans
finiteHeightLimit _ _ (GCustom _) = 0

-- A truth map holds the least fixed point of nominal finite inhabitants. A
-- state key contains a nominal identity and the already-classified bits of its
-- arguments. Classifying a nominal only looks up that key; it never unfolds a
-- declaration, so mutually applied empty cycles stay at bottom.
finiteTruth : PlanEnv -> GenPlan -> OrdMap Unit
finiteTruth env root = finiteTruthLoop env root omEmpty

finiteTruthLoop : PlanEnv -> GenPlan -> OrdMap Unit -> OrdMap Unit
finiteTruthLoop env root truth =
  let states = reachableStates env truth root
  let next = addFiniteStates env truth states truth
  if omSize next == omSize truth then next else finiteTruthLoop env root next

addFiniteStates : PlanEnv ->
  OrdMap Unit ->
  OrdMap GenPlan ->
  OrdMap Unit ->
  OrdMap Unit
addFiniteStates env truth states result =
  addFiniteWords env truth (omKeys states) states result

addFiniteWords : PlanEnv ->
  OrdMap Unit ->
  List String ->
  OrdMap GenPlan ->
  OrdMap Unit ->
  OrdMap Unit
addFiniteWords _ _ [] _ result = result
addFiniteWords env truth (word :: rest) states result =
  let next = match omLookup word states
    Some state =>
      if stateFiniteUnder env truth state then
        omInsert word () result
      else
        result
    None => result
  addFiniteWords env truth rest states next

stateFiniteUnder : PlanEnv -> OrdMap Unit -> GenPlan -> Bool
stateFiniteUnder env truth (nominal@(GNominal key _)) = match planDef env key
  Ok (PlanDef _ _ _ _ ctors) => anyCtorFiniteUnder env truth nominal ctors
  Err _ => False
stateFiniteUnder _ _ _ = False

anyCtorFiniteUnder : PlanEnv -> OrdMap Unit -> GenPlan -> List PlanCtor -> Bool
anyCtorFiniteUnder _ _ _ [] = False
anyCtorFiniteUnder env truth nominal (ctor :: rest) =
  match instantiateCtor env nominal ctor
    Ok fields =>
      allFiniteUnder env truth (fieldPlansOnly fields)
        || anyCtorFiniteUnder env truth nominal rest
    Err _ => anyCtorFiniteUnder env truth nominal rest

allFiniteUnder : PlanEnv -> OrdMap Unit -> List GenPlan -> Bool
allFiniteUnder _ _ [] = True
allFiniteUnder env truth (plan :: rest) =
  abstractFinite env truth plan && allFiniteUnder env truth rest

abstractFinite : PlanEnv -> OrdMap Unit -> GenPlan -> Bool
abstractFinite _ _ GInt = True
abstractFinite _ _ GBool = True
abstractFinite _ _ GFloat = True
abstractFinite _ _ GChar = True
abstractFinite _ _ GString = True
abstractFinite _ _ GUnit = True
abstractFinite _ _ (GList _) = True
abstractFinite _ _ (GArray _) = True
abstractFinite _ _ (GOption _) = True
abstractFinite env truth (GResult err ok) =
  abstractFinite env truth err || abstractFinite env truth ok
abstractFinite env truth (GTuple plans) = allFiniteUnder env truth plans
abstractFinite _ _ (GCustom _) = True
abstractFinite env truth (GNominal key args) =
  omHasKey (stateWord env truth key args) truth

reachableStates : PlanEnv -> OrdMap Unit -> GenPlan -> OrdMap GenPlan
reachableStates env truth root =
  discoverStates env truth [root] (seedArgumentStates env truth root omEmpty)

seedArgumentStates : PlanEnv ->
  OrdMap Unit ->
  GenPlan ->
  OrdMap GenPlan ->
  OrdMap GenPlan
seedArgumentStates env truth (GNominal _ args) states =
  seedPlans env truth args states
seedArgumentStates _ _ _ states = states

seedPlans : PlanEnv ->
  OrdMap Unit ->
  List GenPlan ->
  OrdMap GenPlan ->
  OrdMap GenPlan
seedPlans _ _ [] states = states
seedPlans env truth (plan :: rest) states =
  seedPlans env truth rest (seedPlan env truth plan states)

seedPlan : PlanEnv -> OrdMap Unit -> GenPlan -> OrdMap GenPlan -> OrdMap GenPlan
seedPlan env truth (GList plan) states = seedPlan env truth plan states
seedPlan env truth (GArray plan) states = seedPlan env truth plan states
seedPlan env truth (GOption plan) states = seedPlan env truth plan states
seedPlan env truth (GResult err ok) states =
  seedPlan env truth ok (seedPlan env truth err states)
seedPlan env truth (GTuple plans) states = seedPlans env truth plans states
seedPlan env truth (nominal@(GNominal key args)) states =
  seedPlans
    env
    truth
    args
    (omInsert (stateWord env truth key args) nominal states)
seedPlan _ _ _ states = states

discoverStates : PlanEnv ->
  OrdMap Unit ->
  List GenPlan ->
  OrdMap GenPlan ->
  OrdMap GenPlan
discoverStates _ _ [] states = states
discoverStates env truth (plan :: rest) states = match plan
  GList child => discoverStates env truth (child :: rest) states
  GArray child => discoverStates env truth (child :: rest) states
  GOption child => discoverStates env truth (child :: rest) states
  GResult err ok =>
    discoverStates env truth rest (discoverStates env truth [err, ok] states)
  GTuple plans =>
    discoverStates env truth rest (discoverStates env truth plans states)
  nominal@(GNominal key args) =>
    let word = stateWord env truth key args
    if omHasKey word states then
      discoverStates env truth rest (seedPlans env truth args states)
    else match planDef env key
      Ok (PlanDef _ _ _ _ ctors) =>
        discoverStates
          env
          truth
          rest
          (discoverCtorFields
            env
            truth
            nominal
            ctors
            (omInsert word nominal states))
      Err _ => discoverStates env truth rest (omInsert word nominal states)
  _ => discoverStates env truth rest states

discoverCtorFields : PlanEnv ->
  OrdMap Unit ->
  GenPlan ->
  List PlanCtor ->
  OrdMap GenPlan ->
  OrdMap GenPlan
discoverCtorFields _ _ _ [] states = states
discoverCtorFields env truth nominal (ctor :: rest) states =
  let afterCtor = match instantiateCtor env nominal ctor
    Ok fields => discoverStates env truth (fieldPlansOnly fields) states
    Err _ => states
  discoverCtorFields env truth nominal rest afterCtor

stateWord : PlanEnv -> OrdMap Unit -> TypeKey -> List GenPlan -> String
stateWord env truth key args = "\{typeKeyWord key}#\{stateBits env truth args}"

stateBits : PlanEnv -> OrdMap Unit -> List GenPlan -> String
stateBits _ _ [] = ""
stateBits env truth (plan :: rest) =
  (if abstractFinite env truth plan then "1" else "0")
    ++ stateBits env truth rest

greatestWitnessBound : PlanEnv -> List GenPlan -> Int
greatestWitnessBound _ [] = 0
greatestWitnessBound env (plan :: rest) =
  max (witnessBound env plan) (greatestWitnessBound env rest)

witnessBound : PlanEnv -> GenPlan -> Int
witnessBound _ GInt = 0
witnessBound _ GBool = 0
witnessBound _ GFloat = 0
witnessBound _ GChar = 0
witnessBound _ GString = 0
witnessBound _ GUnit = 0
witnessBound _ (GList _) = 0
witnessBound _ (GArray _) = 0
witnessBound _ (GOption _) = 0
witnessBound env (GResult err ok) =
  max (witnessBound env err) (witnessBound env ok)
witnessBound env (GTuple plans) = greatestWitnessBound env plans
witnessBound env (nominal@(GNominal _ args)) =
  omSize (reachableStates env (finiteTruth env nominal) nominal)
    + greatestWitnessBound env args
witnessBound _ (GCustom _) = 0

findFiniteHeight : PlanEnv -> GenPlan -> Int -> Int -> Option Int
findFiniteHeight _ _ height limit
  | height > limit = None
findFiniteHeight env plan height limit =
  if planFitsHeight env plan height then
    Some height
  else
    findFiniteHeight env plan (height + 1) limit

planFitsHeight : PlanEnv -> GenPlan -> Int -> Bool
planFitsHeight _ _ height
  | height < 0 = False
planFitsHeight _ GInt _ = True
planFitsHeight _ GBool _ = True
planFitsHeight _ GFloat _ = True
planFitsHeight _ GChar _ = True
planFitsHeight _ GString _ = True
planFitsHeight _ GUnit _ = True
planFitsHeight _ (GList _) _ = True
planFitsHeight _ (GArray _) _ = True
planFitsHeight _ (GOption _) _ = True
planFitsHeight env (GResult err ok) height =
  planFitsHeight env err height || planFitsHeight env ok height
planFitsHeight env (GTuple plans) height = allPlansFitHeight env plans height
planFitsHeight _ (GCustom _) _ = True
planFitsHeight env (nominal@(GNominal key _)) height =
  if height <= 0 then
    False
  else match planDef env key
    Ok (PlanDef _ _ _ _ ctors) =>
      anyCtorFitsHeight env nominal ctors (height - 1)
    Err _ => False

anyCtorFitsHeight : PlanEnv -> GenPlan -> List PlanCtor -> Int -> Bool
anyCtorFitsHeight _ _ [] _ = False
anyCtorFitsHeight env nominal (ctor :: rest) height =
  match instantiateCtor env nominal ctor
    Ok fields =>
      allPlansFitHeight env (fieldPlansOnly fields) height
        || anyCtorFitsHeight env nominal rest height
    Err _ => anyCtorFitsHeight env nominal rest height

allPlansFitHeight : PlanEnv -> List GenPlan -> Int -> Bool
allPlansFitHeight _ [] _ = True
allPlansFitHeight env (plan :: rest) height =
  planFitsHeight env plan height && allPlansFitHeight env rest height

allPlansFinite : PlanEnv -> List GenPlan -> Bool
allPlansFinite _ [] = True
allPlansFinite env (plan :: rest) =
  planHasFiniteValue env plan && allPlansFinite env rest

fieldPlansOnly : List (Option String, GenPlan) -> List GenPlan
fieldPlansOnly [] = []
fieldPlansOnly ((_, plan) :: rest) = plan :: fieldPlansOnly rest

allPlansBelow : PlanEnv -> Int -> List GenPlan -> Bool
allPlansBelow _ _ [] = True
allPlansBelow env height (plan :: rest) = match planFiniteHeight env plan []
  Some planHeight => planHeight < height && allPlansBelow env height rest
  None => False

export
planFor : PlanEnv -> String -> String -> Ty -> Result PlanError GenPlan
planFor env propName param ty = match planForGo env propName param ty
  Ok plan =>
    match validateReachableFields env (finiteTruth env plan) plan omEmpty
      Err (PlanError _ _ badTy reason detail) =>
        Err (PlanError propName param badTy reason detail)
      Ok _ =>
        if planHasFiniteValue env plan then
          Ok plan
        else
          Err
            (PlanError
              propName
              param
              ty
              PENoFiniteValue
              "no constructor path reaches finite values")
  Err e => Err e

-- A property may have one finite constructor while another reachable
-- constructor contains a function or another unsupported field. The selected
-- constructor must never turn that planning failure into an engine panic, so
-- check every reachable structural field before handing the plan to a runner.
-- The carrier uses finite/non-finite argument states; it terminates for
-- nonregular recursion while retaining the instantiated generic distinction.
validateReachableFields : PlanEnv ->
  OrdMap Unit ->
  GenPlan ->
  OrdMap Unit ->
  Result PlanError Unit
validateReachableFields _ _ GInt _ = Ok ()
validateReachableFields _ _ GBool _ = Ok ()
validateReachableFields _ _ GFloat _ = Ok ()
validateReachableFields _ _ GChar _ = Ok ()
validateReachableFields _ _ GString _ = Ok ()
validateReachableFields _ _ GUnit _ = Ok ()
validateReachableFields env truth (GList plan) seen =
  validateReachableFields env truth plan seen
validateReachableFields env truth (GArray plan) seen =
  validateReachableFields env truth plan seen
validateReachableFields env truth (GOption plan) seen =
  validateReachableFields env truth plan seen
validateReachableFields env truth (GResult err ok) seen = match (
  validateReachableFields env truth err seen,
  validateReachableFields env truth ok seen,
)
  (Ok _, Ok _) => Ok ()
  (Err e, _) => Err e
  (_, Err e) => Err e
validateReachableFields env truth (GTuple plans) seen =
  validateReachablePlans env truth plans seen
validateReachableFields _ _ (GCustom _) _ = Ok ()
validateReachableFields env truth (nominal@(GNominal key args)) seen =
  let word = stateWord env truth key args
  if omHasKey word seen then
    Ok ()
  else match planDef env key
    Ok (PlanDef _ _ _ _ ctors) =>
      validateReachableCtors env truth nominal ctors (omInsert word () seen)
    Err e => Err e

validateReachablePlans : PlanEnv ->
  OrdMap Unit ->
  List GenPlan ->
  OrdMap Unit ->
  Result PlanError Unit
validateReachablePlans _ _ [] _ = Ok ()
validateReachablePlans env truth (plan :: rest) seen = match (
  validateReachableFields env truth plan seen,
  validateReachablePlans env truth rest seen,
)
  (Ok _, Ok _) => Ok ()
  (Err e, _) => Err e
  (_, Err e) => Err e

validateReachableCtors : PlanEnv ->
  OrdMap Unit ->
  GenPlan ->
  List PlanCtor ->
  OrdMap Unit ->
  Result PlanError Unit
validateReachableCtors _ _ _ [] _ = Ok ()
validateReachableCtors env truth nominal (ctor :: rest) seen = match (
  instantiateCtor env nominal ctor,
  validateReachableCtors env truth nominal rest seen,
)
  (Ok fields, Ok _) =>
    validateReachablePlans env truth (fieldPlansOnly fields) seen
  (Err e, _) => Err e
  (_, Err e) => Err e

-- A list whose element reaches a cycle that crosses a list edge (`Rose Int
-- (List Rose)`) shrinks its length bound by one per level of nominal depth, so
-- the expected fan-out drops below one and the whole value stays small. Every
-- other list keeps the flat bound, which leaves terminating carriers' draws
-- untouched.
export
listLengthBound : PlanEnv -> Int -> GenPlan -> Int
listLengthBound env depth plan =
  if not (planHasFiniteValue env plan) then
    0
  else if planCyclesThroughList env plan then
    max 0 (listLenMax - depth)
  else if depth >= maxGenDepth && planCanDiverge env plan then
    0
  else
    listLenMax

-- The renderer emits the decaying bound over the runtime `depth`.
export
listBoundDecays : PlanEnv -> GenPlan -> Bool
listBoundDecays env plan =
  planHasFiniteValue env plan && planCyclesThroughList env plan

export
planCyclesThroughList : PlanEnv -> GenPlan -> Bool
planCyclesThroughList env plan =
  cyclesThroughListIn env (finiteTruth env plan) plan omEmpty 0

-- `seen` records how many list edges the path had crossed when it entered each
-- carrier state; reaching a state again after crossing more is a cycle that
-- passes through a list.
cyclesThroughListIn : PlanEnv ->
  OrdMap Unit ->
  GenPlan ->
  OrdMap Int ->
  Int ->
  Bool
cyclesThroughListIn env truth (GList p) seen lists =
  cyclesThroughListIn env truth p seen (lists + 1)
cyclesThroughListIn env truth (GArray p) seen lists =
  cyclesThroughListIn env truth p seen (lists + 1)
cyclesThroughListIn env truth (GOption p) seen lists =
  cyclesThroughListIn env truth p seen lists
cyclesThroughListIn env truth (GResult err ok) seen lists =
  cyclesThroughListIn env truth err seen lists
    || cyclesThroughListIn env truth ok seen lists
cyclesThroughListIn env truth (GTuple ps) seen lists =
  anyCyclesThroughList env truth ps seen lists
cyclesThroughListIn env truth (nominal@(GNominal key args)) seen lists =
  let word = stateWord env truth key args
  match omLookup word seen
    Some entered => lists > entered
    None => match planDef env key
      Ok (PlanDef _ _ _ _ ctors) =>
        anyCtorCyclesThroughList
          env
          truth
          nominal
          ctors
          (omInsert word lists seen)
          lists
      Err _ => False
cyclesThroughListIn _ _ _ _ _ = False

anyCyclesThroughList : PlanEnv ->
  OrdMap Unit ->
  List GenPlan ->
  OrdMap Int ->
  Int ->
  Bool
anyCyclesThroughList _ _ [] _ _ = False
anyCyclesThroughList env truth (p :: ps) seen lists =
  cyclesThroughListIn env truth p seen lists
    || anyCyclesThroughList env truth ps seen lists

anyCtorCyclesThroughList : PlanEnv ->
  OrdMap Unit ->
  GenPlan ->
  List PlanCtor ->
  OrdMap Int ->
  Int ->
  Bool
anyCtorCyclesThroughList _ _ _ [] _ _ = False
anyCtorCyclesThroughList env truth nominal (ctor :: rest) seen lists =
  (match instantiateCtor env nominal ctor
      Ok fields =>
        anyCyclesThroughList env truth (fieldPlansOnly fields) seen lists
      Err _ => False)
    || anyCtorCyclesThroughList env truth nominal rest seen lists

-- The empty/none alternatives are part of the same depth policy. A container
-- may still expose a non-recursive payload at the bound, but it cannot enter a
-- recursive plan through its non-empty branch.
export
optionWeights : PlanEnv -> Int -> GenPlan -> List Int
optionWeights env depth plan =
  if not (planHasFiniteValue env plan) then
    [1, 0]
  else if depth >= maxGenDepth && planCanDiverge env plan then
    [1, 0]
  else
    [1, 1]

export
resultWeights : PlanEnv -> Int -> GenPlan -> GenPlan -> List Int
resultWeights env depth err ok =
  if depth >= maxGenDepth then
    [boundPlanWeight env err, boundPlanWeight env ok]
  else
    [finitePlanWeight env err, finitePlanWeight env ok]

finitePlanWeight : PlanEnv -> GenPlan -> Int
finitePlanWeight env plan = if planHasFiniteValue env plan then 1 else 0

boundPlanWeight : PlanEnv -> GenPlan -> Int
boundPlanWeight env plan = if planCanFinishAtBound env plan then 1 else 0

planCanFinishAtBound : PlanEnv -> GenPlan -> Bool
planCanFinishAtBound _ GInt = True
planCanFinishAtBound _ GBool = True
planCanFinishAtBound _ GFloat = True
planCanFinishAtBound _ GChar = True
planCanFinishAtBound _ GString = True
planCanFinishAtBound _ GUnit = True
planCanFinishAtBound _ (GList _) = True
planCanFinishAtBound _ (GArray _) = True
planCanFinishAtBound _ (GOption _) = True
planCanFinishAtBound env (GResult err ok) =
  planCanFinishAtBound env err || planCanFinishAtBound env ok
planCanFinishAtBound env (GTuple plans) = allPlansFinishAtBound env plans
planCanFinishAtBound _ (GCustom _) = True
planCanFinishAtBound env (nominal@(GNominal key _)) = match planDef env key
  Ok (PlanDef _ _ _ _ ctors) => anyBoundCtor env nominal ctors
  Err _ => False

anyBoundCtor : PlanEnv -> GenPlan -> List PlanCtor -> Bool
anyBoundCtor _ _ [] = False
anyBoundCtor env nominal (ctor :: rest) =
  ctorLowersFiniteHeight env nominal ctor || anyBoundCtor env nominal rest

allPlansFinishAtBound : PlanEnv -> List GenPlan -> Bool
allPlansFinishAtBound _ [] = True
allPlansFinishAtBound env (plan :: rest) =
  planCanFinishAtBound env plan && allPlansFinishAtBound env rest

export
planCanDiverge : PlanEnv -> GenPlan -> Bool
planCanDiverge _ GInt = False
planCanDiverge _ GBool = False
planCanDiverge _ GFloat = False
planCanDiverge _ GChar = False
planCanDiverge _ GString = False
planCanDiverge _ GUnit = False
planCanDiverge env (GList p) = planCanDiverge env p
planCanDiverge env (GArray p) = planCanDiverge env p
planCanDiverge env (GOption p) = planCanDiverge env p
planCanDiverge env (GResult a b) = planCanDiverge env a || planCanDiverge env b
planCanDiverge env (GTuple ps) = anyPlanDiverges env ps
planCanDiverge env (nominal@(GNominal _ _)) =
  planCanDivergeNominal env (finiteTruth env nominal) nominal omEmpty
planCanDiverge _ (GCustom _) = False

anyPlanDiverges : PlanEnv -> List GenPlan -> Bool
anyPlanDiverges _ [] = False
anyPlanDiverges env (p :: ps) = planCanDiverge env p || anyPlanDiverges env ps

planCanDivergeNominal : PlanEnv -> OrdMap Unit -> GenPlan -> OrdMap Unit -> Bool
planCanDivergeNominal env truth (nominal@(GNominal key args)) seen =
  let word = stateWord env truth key args
  if omHasKey word seen then
    True
  else match planDef env key
    Ok (PlanDef _ _ _ _ ctors) =>
      anyCtorPlanDiverges env truth nominal ctors (omInsert word () seen)
    Err _ => False
planCanDivergeNominal _ _ _ _ = False

anyCtorPlanDiverges : PlanEnv ->
  OrdMap Unit ->
  GenPlan ->
  List PlanCtor ->
  OrdMap Unit ->
  Bool
anyCtorPlanDiverges _ _ _ [] _ = False
anyCtorPlanDiverges env truth nominal (ctor :: rest) seen =
  ctorPlanDiverges env truth nominal ctor seen
    || anyCtorPlanDiverges env truth nominal rest seen

ctorPlanDiverges : PlanEnv ->
  OrdMap Unit ->
  GenPlan ->
  PlanCtor ->
  OrdMap Unit ->
  Bool
ctorPlanDiverges env truth nominal ctor seen =
  match instantiateCtor env nominal ctor
    Ok fields => anyPlansDivergeSeen env truth (fieldPlansOnly fields) seen
    Err _ => False

anyPlansDivergeSeen : PlanEnv ->
  OrdMap Unit ->
  List GenPlan ->
  OrdMap Unit ->
  Bool
anyPlansDivergeSeen _ _ [] _ = False
anyPlansDivergeSeen env truth (plan :: rest) seen =
  planDivergesSeen env truth plan seen
    || anyPlansDivergeSeen env truth rest seen

planDivergesSeen : PlanEnv -> OrdMap Unit -> GenPlan -> OrdMap Unit -> Bool
planDivergesSeen _ _ GInt _ = False
planDivergesSeen _ _ GBool _ = False
planDivergesSeen _ _ GFloat _ = False
planDivergesSeen _ _ GChar _ = False
planDivergesSeen _ _ GString _ = False
planDivergesSeen _ _ GUnit _ = False
planDivergesSeen env truth (GList plan) seen =
  planDivergesSeen env truth plan seen
planDivergesSeen env truth (GArray plan) seen =
  planDivergesSeen env truth plan seen
planDivergesSeen env truth (GOption plan) seen =
  planDivergesSeen env truth plan seen
planDivergesSeen env truth (GResult err ok) seen =
  planDivergesSeen env truth err seen || planDivergesSeen env truth ok seen
planDivergesSeen env truth (GTuple plans) seen =
  anyPlansDivergeSeen env truth plans seen
planDivergesSeen env truth (nominal@(GNominal _ _)) seen =
  planCanDivergeNominal env truth nominal seen
planDivergesSeen _ _ (GCustom _) _ = False

-- Structural shrink action ordering is shared as data. Both adapters consume
-- these actions in order; value representation and emitted syntax never pick
-- an independent candidate family.
public export data ShrinkAction =
  | DeleteElements
  | ShrinkChildren
  | ReplaceEarlierNullary

export
shrinkActions : GenPlan -> List ShrinkAction
shrinkActions (GList _) = [DeleteElements, ShrinkChildren]
shrinkActions (GArray _) = [DeleteElements, ShrinkChildren]
shrinkActions (GTuple _) = [ShrinkChildren]
shrinkActions (GOption _) = [ReplaceEarlierNullary, ShrinkChildren]
shrinkActions (GResult _ _) = [ShrinkChildren]
shrinkActions (GNominal _ _) = [ReplaceEarlierNullary, ShrinkChildren]
shrinkActions _ = []

-- Integer candidates need source-level rendering natively, so their order is
-- a separate shared policy.  The adapters map the same three steps to their
-- own representation; toward-zero is deliberately last, after zero and half.
public export data IntShrinkStep = IntToZero | IntHalf | IntTowardZero

export
intShrinkSteps : List IntShrinkStep
intShrinkSteps = [IntToZero, IntHalf, IntTowardZero]
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "DataVis" true) (mem "Variant" true) (mem "Field" true) (mem "ConPayload" true) (mem "ImplMethod" true) (mem "sameTyConHead" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "typeTagOf" false) (mem "implRouteKeyWord" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false) (mem "omSize" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "zipL" false))))
(DTypeSig true "structuralRngModulus" (TyCon "Int"))
(DFunDef false "structuralRngModulus" () (ELit (LInt 2147483648)))
(DTypeSig true "structuralRngMultiplier" (TyCon "Int"))
(DFunDef false "structuralRngMultiplier" () (ELit (LInt 1103515245)))
(DTypeSig true "structuralRngIncrement" (TyCon "Int"))
(DFunDef false "structuralRngIncrement" () (ELit (LInt 12345)))
(DTypeSig true "structuralRngMixMultiplier1" (TyCon "Int"))
(DFunDef false "structuralRngMixMultiplier1" () (ELit (LInt 2246822507)))
(DTypeSig true "structuralRngMixMultiplier2" (TyCon "Int"))
(DFunDef false "structuralRngMixMultiplier2" () (ELit (LInt 3266489909)))
(DTypeSig true "structuralRngWordModulus" (TyCon "Int"))
(DFunDef false "structuralRngWordModulus" () (ELit (LInt 4294967296)))
(DTypeSig true "structuralRngWordHalf" (TyCon "Int"))
(DFunDef false "structuralRngWordHalf" () (ELit (LInt 65536)))
(DTypeSig true "structuralRngSeed" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "structuralRngSeed" ((PVar "n")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (EVar "structuralRngModulus")) (EVar "structuralRngModulus")) (EVar "structuralRngModulus")))
(DTypeSig true "structuralRngAdvance" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "structuralRngAdvance" ((PVar "state")) (EBinOp "%" (EBinOp "+" (EBinOp "*" (EVar "state") (EVar "structuralRngMultiplier")) (EVar "structuralRngIncrement")) (EVar "structuralRngModulus")))
(DTypeSig false "structuralRngWord" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "structuralRngWord" ((PVar "n")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (EVar "structuralRngWordModulus")) (EVar "structuralRngWordModulus")) (EVar "structuralRngWordModulus")))
(DTypeSig false "structuralRngMulWord" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "structuralRngMulWord" ((PVar "left") (PVar "right")) (EBlock (DoLet false false (PVar "x") (EApp (EVar "structuralRngWord") (EVar "left"))) (DoLet false false (PVar "y") (EApp (EVar "structuralRngWord") (EVar "right"))) (DoLet false false (PVar "xLow") (EBinOp "%" (EVar "x") (EVar "structuralRngWordHalf"))) (DoLet false false (PVar "xHigh") (EBinOp "/" (EVar "x") (EVar "structuralRngWordHalf"))) (DoLet false false (PVar "yLow") (EBinOp "%" (EVar "y") (EVar "structuralRngWordHalf"))) (DoLet false false (PVar "yHigh") (EBinOp "/" (EVar "y") (EVar "structuralRngWordHalf"))) (DoLet false false (PVar "low") (EBinOp "*" (EVar "xLow") (EVar "yLow"))) (DoLet false false (PVar "cross") (EBinOp "+" (EBinOp "*" (EVar "xLow") (EVar "yHigh")) (EBinOp "*" (EVar "xHigh") (EVar "yLow")))) (DoExpr (EApp (EVar "structuralRngWord") (EBinOp "+" (EVar "low") (EBinOp "*" (EBinOp "%" (EVar "cross") (EVar "structuralRngWordHalf")) (EVar "structuralRngWordHalf")))))))
(DTypeSig true "structuralRngMix" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "structuralRngMix" ((PVar "state")) (EBlock (DoLet false false (PVar "word") (EApp (EVar "structuralRngWord") (EVar "state"))) (DoLet false false (PVar "h1") (EApp (EVar "structuralRngWord") (EApp (EApp (EVar "bitXor") (EVar "word")) (EApp (EApp (EVar "shiftRight") (EVar "word")) (ELit (LInt 16)))))) (DoLet false false (PVar "h2") (EApp (EApp (EVar "structuralRngMulWord") (EVar "h1")) (EVar "structuralRngMixMultiplier1"))) (DoLet false false (PVar "h3") (EApp (EVar "structuralRngWord") (EApp (EApp (EVar "bitXor") (EVar "h2")) (EApp (EApp (EVar "shiftRight") (EVar "h2")) (ELit (LInt 13)))))) (DoLet false false (PVar "h4") (EApp (EApp (EVar "structuralRngMulWord") (EVar "h3")) (EVar "structuralRngMixMultiplier2"))) (DoExpr (EApp (EVar "structuralRngWord") (EApp (EApp (EVar "bitXor") (EVar "h4")) (EApp (EApp (EVar "shiftRight") (EVar "h4")) (ELit (LInt 16))))))))
(DTypeSig true "structuralRngRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "structuralRngRange" ((PVar "word") (PVar "lo") (PVar "hi")) (EBlock (DoLet false false (PVar "width") (EBinOp "+" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<=" (EVar "width") (ELit (LInt 0))) (EVar "lo") (EBinOp "+" (EVar "lo") (EBinOp "%" (EVar "word") (EVar "width")))))))
(DTypeSig true "structuralRngChoose" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "structuralRngChoose" ((PVar "word") (PVar "width")) (EIf (EBinOp "<=" (EVar "width") (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "%" (EVar "word") (EVar "width"))))
(DTypeSig true "deleteEach" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "deleteEach" ((PList)) (EListLit))
(DFunDef false "deleteEach" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "xs") (EApp (EApp (EVar "map") (EApp (EVar "prepend") (EVar "x"))) (EApp (EVar "deleteEach") (EVar "xs")))))
(DTypeSig true "prepend" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "prepend" ((PVar "x") (PVar "xs")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DTypeSig true "replaceEach" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "replaceEach" (PWild (PList)) (EListLit))
(DFunDef false "replaceEach" ((PVar "smaller") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "prependBefore") (EVar "xs"))) (EApp (EVar "smaller") (EVar "x"))) (EApp (EApp (EVar "map") (EApp (EVar "prepend") (EVar "x"))) (EApp (EApp (EVar "replaceEach") (EVar "smaller")) (EVar "xs")))))
(DTypeSig true "prependBefore" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "prependBefore" ((PVar "xs") (PVar "x")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DData Public "TypeKey" () ((variant "TypeKey" (ConPos (TyCon "String") (TyCon "TyConOrigin")))) ())
(DTypeSig true "typeKeyWord" (TyFun (TyCon "TypeKey") (TyCon "String")))
(DFunDef false "typeKeyWord" ((PCon "TypeKey" (PVar "n") (PVar "o"))) (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n")))
(DTypeSig false "sameTypeKey" (TyFun (TyCon "TypeKey") (TyFun (TyCon "TypeKey") (TyCon "Bool"))))
(DFunDef false "sameTypeKey" ((PCon "TypeKey" (PVar "n") (PVar "o")) (PCon "TypeKey" (PVar "n2") (PVar "o2"))) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "n")) (EVar "o")) (EVar "n2")) (EVar "o2")))
(DData Public "PlanVisibility" () ((variant "PlanLocal" (ConPos)) (variant "PlanPublicCtors" (ConPos)) (variant "PlanAbstract" (ConPos))) ())
(DData Public "PlanField" () ((variant "PlanField" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Ty")))) ())
(DData Public "PlanCtor" () ((variant "PlanCtor" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "PlanField"))))) ())
(DData Public "PlanDef" () ((variant "PlanDef" (ConPos (TyCon "TypeKey") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyCon "PlanVisibility") (TyApp (TyCon "List") (TyCon "PlanCtor"))))) ())
(DData Public "CustomPlan" () ((variant "CustomPlan" (ConPos (TyCon "TypeKey") (TyCon "Ty") (TyCon "String")))) ())
(DData Public "GenPlan" () ((variant "GInt" (ConPos)) (variant "GBool" (ConPos)) (variant "GFloat" (ConPos)) (variant "GChar" (ConPos)) (variant "GString" (ConPos)) (variant "GUnit" (ConPos)) (variant "GList" (ConPos (TyCon "GenPlan"))) (variant "GArray" (ConPos (TyCon "GenPlan"))) (variant "GOption" (ConPos (TyCon "GenPlan"))) (variant "GResult" (ConPos (TyCon "GenPlan") (TyCon "GenPlan"))) (variant "GTuple" (ConPos (TyApp (TyCon "List") (TyCon "GenPlan")))) (variant "GNominal" (ConPos (TyCon "TypeKey") (TyApp (TyCon "List") (TyCon "GenPlan")))) (variant "GCustom" (ConPos (TyCon "CustomPlan")))) ())
(DData Public "PlanErrorReason" () ((variant "PEUnboundTyVar" (ConPos)) (variant "PETypeAlias" (ConPos)) (variant "PEFunction" (ConPos)) (variant "PEUnsupportedType" (ConPos)) (variant "PEOpaqueNominal" (ConPos)) (variant "PEAmbiguousNominal" (ConPos)) (variant "PENoFiniteValue" (ConPos)) (variant "PEUnusableArbitrary" (ConPos)) (variant "PEInaccessibleConstructors" (ConPos))) ())
(DData Public "PlanError" () ((variant "PlanError" (ConPos (TyCon "String") (TyCon "String") (TyCon "Ty") (TyCon "PlanErrorReason") (TyCon "String")))) ())
(DTypeSig true "planErrorText" (TyFun (TyCon "PlanError") (TyCon "String")))
(DFunDef false "planErrorText" ((PCon "PlanError" (PVar "propName") (PVar "name") PWild (PVar "reason") (PVar "detail"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "property '")) (EApp (EVar "display") (EVar "propName"))) (ELit (LString "', parameter '"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' cannot be generated: "))) (EApp (EVar "display") (EApp (EVar "reasonText") (EVar "reason")))) (ELit (LString ""))) (EApp (EVar "display") (EIf (EBinOp "==" (EVar "detail") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EVar "detail")) (ELit (LString ")")))))) (ELit (LString ""))))
(DTypeSig false "reasonText" (TyFun (TyCon "PlanErrorReason") (TyCon "String")))
(DFunDef false "reasonText" ((PCon "PEUnboundTyVar")) (ELit (LString "unbound type variable")))
(DFunDef false "reasonText" ((PCon "PETypeAlias")) (ELit (LString "unexpanded type alias")))
(DFunDef false "reasonText" ((PCon "PEFunction")) (ELit (LString "function values have no built-in generator")))
(DFunDef false "reasonText" ((PCon "PEUnsupportedType")) (ELit (LString "unsupported parameter type")))
(DFunDef false "reasonText" ((PCon "PEOpaqueNominal")) (ELit (LString "opaque nominal type")))
(DFunDef false "reasonText" ((PCon "PEAmbiguousNominal")) (ELit (LString "ambiguous unresolved nominal type")))
(DFunDef false "reasonText" ((PCon "PENoFiniteValue")) (ELit (LString "recursive type has no finite constructor")))
(DFunDef false "reasonText" ((PCon "PEUnusableArbitrary")) (ELit (LString "Arbitrary instance cannot be selected for this carrier")))
(DFunDef false "reasonText" ((PCon "PEInaccessibleConstructors")) (ELit (LString "constructors are not visible to this property")))
(DData Public "ArbPlan" () ((variant "ArbPlan" (ConPos (TyCon "Ty") (TyCon "String")))) ())
(DData Public "PlanEnv" () ((variant "PlanEnv" (ConPos (TyCon "String") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "PlanDef"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "ArbPlan"))) (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))) ())
(DData Public "PlanModule" () ((variant "PlanModule" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DTypeSig false "emptyPlanEnv" (TyCon "PlanEnv"))
(DFunDef false "emptyPlanEnv" () (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (ELit (LString ""))) (EVar "omEmpty")) (EVar "omEmpty")) (EVar "omEmpty")) (EVar "omEmpty")))
(DTypeSig true "buildPlanEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "PlanEnv")))
(DFunDef false "buildPlanEnv" ((PVar "decls")) (EApp (EApp (EVar "buildPlanEnvGo") (EVar "decls")) (EVar "emptyPlanEnv")))
(DTypeSig true "buildPlanEnvModules" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))
(DFunDef false "buildPlanEnvModules" ((PVar "root") (PVar "modules")) (EApp (EApp (EVar "pairModules") (EVar "modules")) (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EVar "omEmpty")) (EVar "omEmpty")) (EVar "omEmpty")) (EVar "omEmpty"))))
(DTypeSig false "pairModules" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))
(DFunDef false "pairModules" ((PList) (PVar "env")) (EApp (EVar "Ok") (EVar "env")))
(DFunDef false "pairModules" ((PCons (PCon "PlanModule" (PVar "mid") (PVar "raw") (PVar "runtime")) (PVar "rest")) (PVar "env")) (EMatch (EApp (EApp (EApp (EApp (EVar "pairModuleDecls") (EVar "mid")) (EVar "raw")) (EVar "runtime")) (EVar "env")) (arm (PCon "Ok" (PVar "env2")) () (EApp (EApp (EVar "pairModules") (EVar "rest")) (EVar "env2"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "pairModuleDecls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "PlanEnv") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))))
(DFunDef false "pairModuleDecls" ((PVar "mid") (PVar "raw") (PVar "runtime") (PVar "env")) (EIf (EApp (EApp (EVar "rawNominalsPresent") (EVar "raw")) (EVar "runtime")) (EApp (EApp (EApp (EApp (EVar "pairRuntimeDecls") (EVar "mid")) (EApp (EApp (EVar "rawNominalMap") (EVar "raw")) (EVar "omEmpty"))) (EVar "runtime")) (EVar "env")) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw nominal declaration has no runtime counterpart"))))))
(DTypeSig false "rawNominalsPresent" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "rawNominalsPresent" ((PList) PWild) (EVar "True"))
(DFunDef false "rawNominalsPresent" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "runtime")) (EApp (EApp (EVar "rawNominalsPresent") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "runtime")))
(DFunDef false "rawNominalsPresent" ((PCons (PRec "DData" ((rf "dataName" (PVar "name"))) false) (PVar "rest")) (PVar "runtime")) (EBinOp "&&" (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EVar "runtime")) (EApp (EApp (EVar "rawNominalsPresent") (EVar "rest")) (EVar "runtime"))))
(DFunDef false "rawNominalsPresent" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "name"))) false) (PVar "rest")) (PVar "runtime")) (EBinOp "&&" (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EVar "runtime")) (EApp (EApp (EVar "rawNominalsPresent") (EVar "rest")) (EVar "runtime"))))
(DFunDef false "rawNominalsPresent" ((PCons PWild (PVar "rest")) (PVar "runtime")) (EApp (EApp (EVar "rawNominalsPresent") (EVar "rest")) (EVar "runtime")))
(DTypeSig false "runtimeHasNominal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "runtimeHasNominal" (PWild (PList)) (EVar "False"))
(DFunDef false "runtimeHasNominal" ((PVar "name") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "runtimeHasNominal" ((PVar "name") (PCons (PRec "DData" ((rf "dataName" (PVar "actual"))) false) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "name") (EVar "actual")) (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EVar "rest"))))
(DFunDef false "runtimeHasNominal" ((PVar "name") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "actual"))) false) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "name") (EVar "actual")) (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EVar "rest"))))
(DFunDef false "runtimeHasNominal" ((PVar "name") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EVar "rest")))
(DTypeSig false "rawNominalMap" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "Decl")))))
(DFunDef false "rawNominalMap" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "rawNominalMap" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "rawNominalMap") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "rawNominalMap" ((PCons (PAs "d" (PRec "DData" ((rf "dataName" (PVar "name"))) false)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "rawNominalMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "d")) (EVar "acc"))))
(DFunDef false "rawNominalMap" ((PCons (PAs "d" (PRec "DNewtype" ((rf "newtypeName" (PVar "name"))) false)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "rawNominalMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "d")) (EVar "acc"))))
(DFunDef false "rawNominalMap" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "rawNominalMap") (EVar "rest")) (EVar "acc")))
(DTypeSig false "pairRuntimeDecls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "PlanEnv") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))))
(DFunDef false "pairRuntimeDecls" (PWild PWild (PList) (PVar "env")) (EApp (EVar "Ok") (EVar "env")))
(DFunDef false "pairRuntimeDecls" ((PVar "mid") (PVar "rawMap") (PCons (PVar "runtime") (PVar "rest")) (PVar "env")) (EMatch (EApp (EApp (EApp (EApp (EVar "pairRuntimeDecl") (EVar "mid")) (EVar "rawMap")) (EVar "runtime")) (EVar "env")) (arm (PCon "Ok" (PVar "env2")) () (EApp (EApp (EApp (EApp (EVar "pairRuntimeDecls") (EVar "mid")) (EVar "rawMap")) (EVar "rest")) (EVar "env2"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "pairRuntimeDecl" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Decl")) (TyFun (TyCon "Decl") (TyFun (TyCon "PlanEnv") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))))
(DFunDef false "pairRuntimeDecl" ((PVar "mid") (PVar "rawMap") (PCon "DAttrib" PWild (PVar "d")) (PVar "env")) (EApp (EApp (EApp (EApp (EVar "pairRuntimeDecl") (EVar "mid")) (EVar "rawMap")) (EVar "d")) (EVar "env")))
(DFunDef false "pairRuntimeDecl" ((PVar "mid") (PVar "rawMap") (PAs "runtime" (PRec "DData" ((rf "dataName" (PVar "name"))) false)) (PVar "env")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rawMap")) (arm (PCon "Some" (PVar "raw")) () (EApp (EApp (EApp (EApp (EVar "pairPlanDecl") (EVar "mid")) (EVar "raw")) (EVar "runtime")) (EVar "env"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "pairError") (EBinOp "++" (EBinOp "++" (ELit (LString "runtime data '")) (EVar "name")) (ELit (LString "' has no raw declaration"))))))))
(DFunDef false "pairRuntimeDecl" ((PVar "mid") (PVar "rawMap") (PAs "runtime" (PRec "DNewtype" ((rf "newtypeName" (PVar "name"))) false)) (PVar "env")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rawMap")) (arm (PCon "Some" (PVar "raw")) () (EApp (EApp (EApp (EApp (EVar "pairPlanDecl") (EVar "mid")) (EVar "raw")) (EVar "runtime")) (EVar "env"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "pairError") (EBinOp "++" (EBinOp "++" (ELit (LString "runtime newtype '")) (EVar "name")) (ELit (LString "' has no raw declaration"))))))))
(DFunDef false "pairRuntimeDecl" (PWild PWild (PVar "runtime") (PVar "env")) (EApp (EVar "Ok") (EApp (EApp (EVar "addPlanDeclRuntimeOnly") (EVar "runtime")) (EVar "env"))))
(DTypeSig false "addPlanDeclRuntimeOnly" (TyFun (TyCon "Decl") (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "addPlanDeclRuntimeOnly" ((PVar "runtime") (PVar "env")) (EApp (EApp (EVar "addPlanDecl") (EVar "runtime")) (EVar "env")))
(DTypeSig false "pairError" (TyFun (TyCon "String") (TyCon "PlanError")))
(DFunDef false "pairError" ((PVar "detail")) (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (ELit (LString ""))) (ELit (LString ""))) (EApp (EVar "TyVar") (ELit (LString "")))) (EVar "PEUnsupportedType")) (EVar "detail")))
(DTypeSig false "pairPlanDecl" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyFun (TyCon "Decl") (TyFun (TyCon "PlanEnv") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))))
(DFunDef false "pairPlanDecl" ((PVar "mid") (PCon "DAttrib" PWild (PVar "raw")) (PCon "DAttrib" PWild (PVar "runtime")) (PVar "env")) (EApp (EApp (EApp (EApp (EVar "pairPlanDecl") (EVar "mid")) (EVar "raw")) (EVar "runtime")) (EVar "env")))
(DFunDef false "pairPlanDecl" ((PVar "mid") (PRec "DData" ((rf "dataName" (PVar "rawName")) (rf "dataCtors" (PVar "rawCtors"))) false) (PRec "DData" ((rf "dataName" (PVar "runtimeName")) (rf "dataParams" (PVar "ps")) (rf "dataCtors" (PVar "runtimeCtors")) (rf "dataVis" (PVar "vis")) (rf "dataOrigin" (PVar "o"))) false) (PVar "env")) (EIf (EBinOp "==" (EVar "rawName") (EVar "runtimeName")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "TypeKey") (EVar "runtimeName")) (EVar "o"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "ctors")) (EApp (EApp (EVar "insertDef") (EApp (EApp (EApp (EApp (EApp (EVar "PlanDef") (EVar "key")) (EApp (EVar "ownerOf") (EVar "o"))) (EVar "ps")) (EApp (EVar "visibilityOf") (EVar "vis"))) (EVar "ctors"))) (EVar "env")))) (EApp (EApp (EVar "pairCtors") (EVar "rawCtors")) (EVar "runtimeCtors"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "pairPlanDecl" ((PVar "mid") (PRec "DNewtype" ((rf "newtypeName" (PVar "rawName")) (rf "newtypeCtor" (PVar "rawCtor"))) false) (PRec "DNewtype" ((rf "newtypeName" (PVar "runtimeName")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeCtor" (PVar "runtimeCtor")) (rf "newtypeFieldTy" (PVar "fieldTy")) (rf "newtypePub" (PVar "pub")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "env")) (EIf (EBinOp "==" (EVar "rawName") (EVar "runtimeName")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "TypeKey") (EVar "runtimeName")) (EVar "o"))) (DoLet false false (PVar "def") (EApp (EApp (EApp (EApp (EApp (EVar "PlanDef") (EVar "key")) (EApp (EVar "ownerOf") (EVar "o"))) (EVar "ps")) (EApp (EVar "newtypeVisibility") (EVar "pub"))) (EListLit (EApp (EApp (EApp (EVar "PlanCtor") (EVar "rawCtor")) (EVar "runtimeCtor")) (EListLit (EApp (EApp (EVar "PlanField") (EVar "None")) (EVar "fieldTy"))))))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EVar "insertDef") (EVar "def")) (EVar "env"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "pairPlanDecl" (PWild PWild PWild PWild) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw and runtime nominal declarations disagree")))))
(DTypeSig false "pairCtors" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "PlanCtor"))))))
(DFunDef false "pairCtors" ((PList) (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "pairCtors" ((PList) PWild) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime constructor counts disagree")))))
(DFunDef false "pairCtors" (PWild (PList)) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime constructor counts disagree")))))
(DFunDef false "pairCtors" ((PCons (PCon "Variant" (PVar "rawName") (PVar "rawPayload")) (PVar "raws")) (PCons (PCon "Variant" (PVar "runtimeName") (PVar "runtimePayload")) (PVar "runtimes"))) (EMatch (ETuple (EApp (EApp (EVar "pairFields") (EVar "rawPayload")) (EVar "runtimePayload")) (EApp (EApp (EVar "pairCtors") (EVar "raws")) (EVar "runtimes"))) (arm (PTuple (PCon "Ok" (PVar "fields")) (PCon "Ok" (PVar "rest"))) () (EApp (EVar "Ok") (EBinOp "::" (EApp (EApp (EApp (EVar "PlanCtor") (EVar "rawName")) (EVar "runtimeName")) (EVar "fields")) (EVar "rest")))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "pairFields" (TyFun (TyCon "ConPayload") (TyFun (TyCon "ConPayload") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "PlanField"))))))
(DFunDef false "pairFields" ((PCon "ConPos" (PVar "rawTys")) (PCon "ConPos" (PVar "runtimeTys"))) (EIf (EBinOp "==" (EApp (EVar "listLength") (EVar "rawTys")) (EApp (EVar "listLength") (EVar "runtimeTys"))) (EApp (EVar "Ok") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "PlanField") (EVar "None")) (EVar "t")))) (EVar "runtimeTys"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "pairFields" ((PCon "ConNamed" (PVar "rawFields") PWild) (PCon "ConNamed" (PVar "runtimeFields") PWild)) (EApp (EApp (EVar "pairNamedFields") (EVar "rawFields")) (EVar "runtimeFields")))
(DFunDef false "pairFields" (PWild PWild) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime constructor payloads disagree")))))
(DTypeSig false "pairNamedFields" (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "PlanField"))))))
(DFunDef false "pairNamedFields" ((PList) (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "pairNamedFields" ((PList) PWild) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime named field counts disagree")))))
(DFunDef false "pairNamedFields" (PWild (PList)) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime named field counts disagree")))))
(DFunDef false "pairNamedFields" ((PCons (PCon "Field" (PVar "rawName") PWild) (PVar "raws")) (PCons (PCon "Field" (PVar "runtimeName") (PVar "runtimeTy")) (PVar "runtimes"))) (EIf (EBinOp "==" (EVar "rawName") (EVar "runtimeName")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EApp (EApp (EVar "PlanField") (EApp (EVar "Some") (EVar "rawName"))) (EVar "runtimeTy")) (EVar "_s")))) (EApp (EApp (EVar "pairNamedFields") (EVar "raws")) (EVar "runtimes"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "pairNamedFields" (PWild PWild) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime named field names disagree")))))
(DTypeSig false "listLength" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "listLength" ((PList)) (ELit (LInt 0)))
(DFunDef false "listLength" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLength") (EVar "xs"))))
(DTypeSig false "buildPlanEnvGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "buildPlanEnvGo" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "buildPlanEnvGo" ((PCons (PVar "d") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "buildPlanEnvGo") (EVar "rest")) (EApp (EApp (EVar "addPlanDecl") (EVar "d")) (EVar "env"))))
(DTypeSig false "addPlanDecl" (TyFun (TyCon "Decl") (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "addPlanDecl" ((PCon "DAttrib" PWild (PVar "d")) (PVar "env")) (EApp (EApp (EVar "addPlanDecl") (EVar "d")) (EVar "env")))
(DFunDef false "addPlanDecl" ((PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataCtors" (PVar "cs")) (rf "dataVis" (PVar "vis")) (rf "dataOrigin" (PVar "o"))) false) (PVar "env")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "TypeKey") (EVar "n")) (EVar "o"))) (DoLet false false (PVar "def") (EApp (EApp (EApp (EApp (EApp (EVar "PlanDef") (EVar "key")) (EApp (EVar "ownerOf") (EVar "o"))) (EVar "ps")) (EApp (EVar "visibilityOf") (EVar "vis"))) (EApp (EApp (EVar "map") (EVar "ctorOfVariant")) (EVar "cs")))) (DoExpr (EApp (EApp (EVar "insertDef") (EVar "def")) (EVar "env")))))
(DFunDef false "addPlanDecl" ((PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeCtor" (PVar "c")) (rf "newtypeFieldTy" (PVar "t")) (rf "newtypePub" (PVar "pub")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "env")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "TypeKey") (EVar "n")) (EVar "o"))) (DoLet false false (PVar "def") (EApp (EApp (EApp (EApp (EApp (EVar "PlanDef") (EVar "key")) (EApp (EVar "ownerOf") (EVar "o"))) (EVar "ps")) (EApp (EVar "newtypeVisibility") (EVar "pub"))) (EListLit (EApp (EApp (EApp (EVar "PlanCtor") (EVar "c")) (EVar "c")) (EListLit (EApp (EApp (EVar "PlanField") (EVar "None")) (EVar "t"))))))) (DoExpr (EApp (EApp (EVar "insertDef") (EVar "def")) (EVar "env")))))
(DFunDef false "addPlanDecl" ((PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasOrigin" (PVar "o"))) false) (PCon "PlanEnv" (PVar "root") (PVar "defs") (PVar "arbs") (PVar "bad") (PVar "aliases"))) (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EVar "defs")) (EVar "arbs")) (EVar "bad")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n"))) (ELit LUnit)) (EVar "aliases"))))
(DFunDef false "addPlanDecl" ((PVar "d") (PVar "env")) (EApp (EApp (EVar "addArbitrary") (EVar "d")) (EVar "env")))
(DTypeSig false "visibilityOf" (TyFun (TyCon "DataVis") (TyCon "PlanVisibility")))
(DFunDef false "visibilityOf" ((PCon "VisPrivate")) (EVar "PlanLocal"))
(DFunDef false "visibilityOf" ((PCon "VisPublic")) (EVar "PlanPublicCtors"))
(DFunDef false "visibilityOf" ((PCon "VisAbstract")) (EVar "PlanAbstract"))
(DTypeSig false "newtypeVisibility" (TyFun (TyCon "Bool") (TyCon "PlanVisibility")))
(DFunDef false "newtypeVisibility" (PWild) (EVar "PlanLocal"))
(DTypeSig false "ownerOf" (TyFun (TyCon "TyConOrigin") (TyCon "String")))
(DFunDef false "ownerOf" ((PCon "OriginModule" (PVar "m"))) (EVar "m"))
(DFunDef false "ownerOf" (PWild) (ELit (LString "")))
(DTypeSig false "ctorOfVariant" (TyFun (TyCon "Variant") (TyCon "PlanCtor")))
(DFunDef false "ctorOfVariant" ((PCon "Variant" (PVar "c") (PCon "ConPos" (PVar "ts")))) (EApp (EApp (EApp (EVar "PlanCtor") (EVar "c")) (EVar "c")) (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "PlanField") (EVar "None")) (EVar "t")))) (EVar "ts"))))
(DFunDef false "ctorOfVariant" ((PCon "Variant" (PVar "c") (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EApp (EVar "PlanCtor") (EVar "c")) (EVar "c")) (EApp (EApp (EVar "map") (EVar "namedField")) (EVar "fs"))))
(DTypeSig false "namedField" (TyFun (TyCon "Field") (TyCon "PlanField")))
(DFunDef false "namedField" ((PCon "Field" (PVar "n") (PVar "t"))) (EApp (EApp (EVar "PlanField") (EApp (EVar "Some") (EVar "n"))) (EVar "t")))
(DTypeSig false "addArbitrary" (TyFun (TyCon "Decl") (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "addArbitrary" ((PCon "DAttrib" PWild (PVar "d")) (PVar "env")) (EApp (EApp (EVar "addArbitrary") (EVar "d")) (EVar "env")))
(DFunDef false "addArbitrary" ((PRec "DImpl" ((rf "iface" (PLit (LString "Arbitrary"))) (rf "implOrigin" (PCon "OriginModule" (PLit (LString "core")))) (rf "tys" (PList (PVar "carrier")))) false) (PVar "env")) (EApp (EApp (EVar "insertArb") (EApp (EApp (EVar "ArbPlan") (EVar "carrier")) (EApp (EVar "arbCarrierWord") (EVar "carrier")))) (EVar "env")))
(DFunDef false "addArbitrary" (PWild (PVar "env")) (EVar "env"))
(DTypeSig false "arbCarrierWord" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "arbCarrierWord" ((PVar "ty")) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EApp (EVar "OriginModule") (ELit (LString "core")))) (ELit (LString "Arbitrary"))) (EListLit (EVar "ty"))) (EVar "None")))
(DTypeSig false "insertDef" (TyFun (TyCon "PlanDef") (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "insertDef" ((PAs "def" (PCon "PlanDef" (PVar "key") PWild PWild PWild PWild)) (PCon "PlanEnv" (PVar "root") (PVar "defs") (PVar "arbs") (PVar "bad") (PVar "aliases"))) (EBlock (DoLet false false (PVar "word") (EApp (EVar "typeKeyWord") (EVar "key"))) (DoLet false false (PVar "prior") (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "defs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EBinOp "::" (EVar "def") (EVar "prior"))) (EVar "defs"))) (EVar "arbs")) (EVar "bad")) (EVar "aliases")))))
(DTypeSig false "insertArb" (TyFun (TyCon "ArbPlan") (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "insertArb" ((PAs "arb" (PCon "ArbPlan" (PVar "carrier") PWild)) (PCon "PlanEnv" (PVar "root") (PVar "defs") (PVar "arbs") (PVar "bad") (PVar "aliases"))) (EMatch (EApp (EVar "headKey") (EVar "carrier")) (arm (PCon "Some" (PVar "key")) () (EBlock (DoLet false false (PVar "word") (EApp (EVar "typeKeyWord") (EVar "key"))) (DoLet false false (PVar "prior") (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "arbs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EVar "defs")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EBinOp "::" (EVar "arb") (EVar "prior"))) (EVar "arbs"))) (EVar "bad")) (EVar "aliases"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EVar "defs")) (EVar "arbs")) (EVar "bad")) (EVar "aliases")))))
(DTypeSig false "optionList" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "optionList" ((PCon "None")) (EListLit))
(DFunDef false "optionList" ((PCon "Some" (PVar "xs"))) (EVar "xs"))
(DTypeSig false "planForGo" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "GenPlan")))))))
(DFunDef false "planForGo" (PWild (PVar "propName") (PVar "param") (PAs "ty" (PCon "TyVar" PWild))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "ty")) (EVar "PEUnboundTyVar")) (ELit (LString "")))))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "Int"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GInt")))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "Bool"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GBool")))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "Float"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GFloat")))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "Char"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GChar")))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "String"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GString")))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "Unit"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GUnit")))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "List"))) (rf "tyConOrigin" (PVar "o"))) false) (PVar "t"))) (EIf (EApp (EVar "builtinOrigin") (EVar "o")) (EApp (EApp (EVar "map") (EVar "GList")) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Array"))) (rf "tyConOrigin" (PVar "o"))) false) (PVar "t"))) (EIf (EApp (EVar "builtinOrigin") (EVar "o")) (EApp (EApp (EVar "map") (EVar "GArray")) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Option"))) (rf "tyConOrigin" (PVar "o"))) false) (PVar "t"))) (EIf (EApp (EVar "builtinOrigin") (EVar "o")) (EApp (EApp (EVar "map") (EVar "GOption")) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyApp" (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Result"))) (rf "tyConOrigin" (PVar "o"))) false) (PVar "e")) (PVar "a"))) (EIf (EApp (EVar "builtinOrigin") (EVar "o")) (EApp (EApp (EApp (EVar "map2") (EVar "GResult")) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "a"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PVar "ty")) (EIf (EApp (EVar "builtinTupleSpine") (EVar "ty")) (EApp (EApp (EVar "map") (EVar "GTuple")) (EApp (EApp (EApp (EApp (EVar "planMany") (EVar "env")) (EVar "propName")) (EVar "param")) (EApp (EVar "planArgs") (EVar "ty")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "map") (EVar "GTuple")) (EApp (EApp (EApp (EApp (EVar "planMany") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "ts"))))
(DFunDef false "planForGo" (PWild (PVar "propName") (PVar "param") (PAs "ty" (PCon "TyFun" PWild PWild))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "ty")) (EVar "PEFunction")) (ELit (LString "")))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t")))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t")))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t")))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PVar "ty")) (EMatch (EApp (EVar "headKey") (EVar "ty")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "ty")) (EVar "PEUnsupportedType")) (ELit (LString ""))))) (arm (PCon "Some" (PVar "key")) () (EApp (EApp (EApp (EApp (EApp (EVar "planNominal") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "key")) (EApp (EVar "planArgs") (EVar "ty"))))))
(DTypeSig false "builtinOrigin" (TyFun (TyCon "TyConOrigin") (TyCon "Bool")))
(DFunDef false "builtinOrigin" ((PCon "OriginBuiltin")) (EVar "True"))
(DFunDef false "builtinOrigin" ((PCon "OriginModule" (PLit (LString "core")))) (EVar "True"))
(DFunDef false "builtinOrigin" (PWild) (EVar "False"))
(DTypeSig false "builtinTupleSpine" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "builtinTupleSpine" ((PVar "ty")) (EMatch (EApp (EVar "headKey") (EVar "ty")) (arm (PCon "Some" (PCon "TypeKey" (PLit (LString "__tuple2__")) (PCon "OriginBuiltin"))) () (EBinOp "==" (EApp (EVar "listLength") (EApp (EVar "planArgs") (EVar "ty"))) (ELit (LInt 2)))) (arm (PCon "Some" (PCon "TypeKey" (PLit (LString "__tuple3__")) (PCon "OriginBuiltin"))) () (EBinOp "==" (EApp (EVar "listLength") (EApp (EVar "planArgs") (EVar "ty"))) (ELit (LInt 3)))) (arm (PCon "Some" (PCon "TypeKey" (PLit (LString "__tuple4__")) (PCon "OriginBuiltin"))) () (EBinOp "==" (EApp (EVar "listLength") (EApp (EVar "planArgs") (EVar "ty"))) (ELit (LInt 4)))) (arm (PCon "Some" (PCon "TypeKey" (PLit (LString "__tuple5__")) (PCon "OriginBuiltin"))) () (EBinOp "==" (EApp (EVar "listLength") (EApp (EVar "planArgs") (EVar "ty"))) (ELit (LInt 5)))) (arm PWild () (EVar "False"))))
(DTypeSig false "headKey" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "TypeKey"))))
(DFunDef false "headKey" ((PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false)) (EApp (EVar "Some") (EApp (EApp (EVar "TypeKey") (EVar "n")) (EVar "o"))))
(DFunDef false "headKey" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "headKey") (EVar "f")))
(DFunDef false "headKey" (PWild) (EVar "None"))
(DTypeSig false "planArgs" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "planArgs" ((PVar "t")) (EApp (EApp (EVar "planArgsGo") (EListLit)) (EVar "t")))
(DTypeSig false "planArgsGo" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "planArgsGo" ((PVar "acc") (PCon "TyApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "planArgsGo") (EBinOp "::" (EVar "a") (EVar "acc"))) (EVar "f")))
(DFunDef false "planArgsGo" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "planNominal" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "GenPlan"))))))))
(DFunDef false "planNominal" ((PCon "PlanEnv" (PVar "root") (PVar "defs") (PVar "arbs") (PVar "bad") (PVar "aliases")) (PVar "propName") (PVar "param") (PVar "key") (PVar "args")) (EBlock (DoLet false false (PVar "carrier") (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "selectedCustom") (EVar "key")) (EVar "carrier")) (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EApp (EVar "typeKeyWord") (EVar "key"))) (EVar "arbs")))) (arm (PCon "Err" (PVar "detail")) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "carrier")) (EVar "PEUnusableArbitrary")) (EVar "detail")))) (arm (PCon "Ok" (PCon "Some" (PVar "custom"))) () (EApp (EVar "Ok") (EApp (EVar "GCustom") (EVar "custom")))) (arm (PCon "Ok" (PCon "None")) () (EMatch (EApp (EApp (EVar "matchingDef") (EVar "key")) (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EApp (EVar "typeKeyWord") (EVar "key"))) (EVar "defs")))) (arm (PCon "None") ((GBool (EApp (EVar "isSome") (EApp (EApp (EVar "omLookup") (EApp (EVar "typeKeyWord") (EVar "key"))) (EVar "aliases"))))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PETypeAlias")) (ELit (LString ""))))) (arm (PCon "None") ((GBool (EApp (EApp (EVar "hasAmbiguousUnresolved") (EVar "key")) (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EApp (EVar "typeKeyWord") (EVar "key"))) (EVar "defs")))))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PEAmbiguousNominal")) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PEOpaqueNominal")) (ELit (LString "no visible data declaration"))))) (arm (PCon "Some" (PCon "PlanDef" PWild (PVar "owner") PWild (PCon "PlanAbstract") PWild)) ((GBool (EBinOp "/=" (EVar "owner") (EVar "root")))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PEOpaqueNominal")) (ELit (LString ""))))) (arm (PCon "Some" (PCon "PlanDef" PWild (PVar "owner") PWild (PCon "PlanLocal") PWild)) ((GBool (EBinOp "/=" (EVar "owner") (EVar "root")))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PEInaccessibleConstructors")) (ELit (LString ""))))) (arm (PCon "Some" (PCon "PlanDef" PWild PWild PWild PWild (PList))) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PENoFiniteValue")) (ELit (LString "no constructors"))))) (arm (PCon "Some" (PCon "PlanDef" PWild PWild PWild PWild PWild)) () (EApp (EApp (EVar "map") (EApp (EVar "GNominal") (EVar "key"))) (EApp (EApp (EApp (EApp (EVar "planMany") (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EVar "defs")) (EVar "arbs")) (EVar "bad")) (EVar "aliases"))) (EVar "propName")) (EVar "param")) (EVar "args"))))))))))
(DTypeSig false "selectedCustom" (TyFun (TyCon "TypeKey") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "ArbPlan")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "CustomPlan")))))))
(DFunDef false "selectedCustom" ((PVar "key") (PVar "carrier") (PVar "candidates")) (EMatch (EApp (EApp (EVar "exactArbs") (EVar "carrier")) (EVar "candidates")) (arm (PList) () (EMatch (EApp (EApp (EVar "matchingArbs") (EVar "carrier")) (EVar "candidates")) (arm (PList) () (EApp (EVar "Ok") (EVar "None"))) (arm PWild () (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "CustomPlan") (EVar "key")) (EVar "carrier")) (EApp (EVar "arbCarrierWord") (EVar "carrier")))))))) (arm (PList PWild) () (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "CustomPlan") (EVar "key")) (EVar "carrier")) (EApp (EVar "arbCarrierWord") (EVar "carrier")))))) (arm PWild () (EApp (EVar "Err") (ELit (LString "multiple exact Arbitrary instances select this carrier"))))))
(DTypeSig false "exactArbs" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "ArbPlan")) (TyApp (TyCon "List") (TyCon "ArbPlan")))))
(DFunDef false "exactArbs" (PWild (PList)) (EListLit))
(DFunDef false "exactArbs" ((PVar "carrier") (PCons (PAs "arb" (PCon "ArbPlan" (PVar "pattern") PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "arbCarrierWord") (EVar "pattern")) (EApp (EVar "arbCarrierWord") (EVar "carrier"))) (EBinOp "::" (EVar "arb") (EApp (EApp (EVar "exactArbs") (EVar "carrier")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "exactArbs") (EVar "carrier")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchingArbs" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "ArbPlan")) (TyApp (TyCon "List") (TyCon "ArbPlan")))))
(DFunDef false "matchingArbs" (PWild (PList)) (EListLit))
(DFunDef false "matchingArbs" ((PVar "carrier") (PCons (PAs "arb" (PCon "ArbPlan" (PVar "pattern") PWild)) (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "matchArbCarrier") (EVar "pattern")) (EVar "carrier")) (EVar "omEmpty")) (arm (PCon "Some" PWild) () (EBinOp "::" (EVar "arb") (EApp (EApp (EVar "matchingArbs") (EVar "carrier")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "matchingArbs") (EVar "carrier")) (EVar "rest")))))
(DTypeSig false "matchArbCarrier" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "OrdMap") (TyCon "Ty")))))))
(DFunDef false "matchArbCarrier" ((PCon "TyVar" (PVar "name")) (PVar "actual") (PVar "bindings")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "bindings")) (arm (PCon "Some" (PVar "bound")) () (EIf (EBinOp "==" (EApp (EVar "arbCarrierWord") (EVar "bound")) (EApp (EVar "arbCarrierWord") (EVar "actual"))) (EApp (EVar "Some") (EVar "bindings")) (EVar "None"))) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "actual")) (EVar "bindings"))))))
(DFunDef false "matchArbCarrier" ((PCon "TyApp" (PVar "pf") (PVar "pa")) (PCon "TyApp" (PVar "af") (PVar "aa")) (PVar "bindings")) (EMatch (EApp (EApp (EApp (EVar "matchArbCarrier") (EVar "pf")) (EVar "af")) (EVar "bindings")) (arm (PCon "Some" (PVar "next")) () (EApp (EApp (EApp (EVar "matchArbCarrier") (EVar "pa")) (EVar "aa")) (EVar "next"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "matchArbCarrier" ((PCon "TyTuple" (PVar "ps")) (PCon "TyTuple" (PVar "actuals")) (PVar "bindings")) (EApp (EApp (EApp (EVar "matchArbCarriers") (EVar "ps")) (EVar "actuals")) (EVar "bindings")))
(DFunDef false "matchArbCarrier" ((PVar "pattern") (PVar "actual") (PVar "bindings")) (EIf (EBinOp "==" (EApp (EVar "arbCarrierWord") (EVar "pattern")) (EApp (EVar "arbCarrierWord") (EVar "actual"))) (EApp (EVar "Some") (EVar "bindings")) (EVar "None")))
(DTypeSig false "matchArbCarriers" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "OrdMap") (TyCon "Ty")))))))
(DFunDef false "matchArbCarriers" ((PList) (PList) (PVar "bindings")) (EApp (EVar "Some") (EVar "bindings")))
(DFunDef false "matchArbCarriers" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "restActuals")) (PVar "bindings")) (EMatch (EApp (EApp (EApp (EVar "matchArbCarrier") (EVar "p")) (EVar "a")) (EVar "bindings")) (arm (PCon "Some" (PVar "next")) () (EApp (EApp (EApp (EVar "matchArbCarriers") (EVar "ps")) (EVar "restActuals")) (EVar "next"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "matchArbCarriers" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "matchingDef" (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "PlanDef")) (TyApp (TyCon "Option") (TyCon "PlanDef")))))
(DFunDef false "matchingDef" (PWild (PList)) (EVar "None"))
(DFunDef false "matchingDef" ((PVar "key") (PCons (PAs "d" (PCon "PlanDef" (PVar "actual") PWild PWild PWild PWild)) (PVar "rest"))) (EIf (EApp (EApp (EVar "sameTypeKey") (EVar "key")) (EVar "actual")) (EApp (EVar "Some") (EVar "d")) (EApp (EApp (EVar "matchingDef") (EVar "key")) (EVar "rest"))))
(DTypeSig false "hasAmbiguousUnresolved" (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "PlanDef")) (TyCon "Bool"))))
(DFunDef false "hasAmbiguousUnresolved" ((PCon "TypeKey" (PVar "n") (PCon "OriginUnresolved")) (PVar "defs")) (EBinOp ">" (EApp (EVar "listLength") (EVar "defs")) (ELit (LInt 1))))
(DFunDef false "hasAmbiguousUnresolved" (PWild PWild) (EVar "False"))
(DTypeSig false "rebuildTy" (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "rebuildTy" ((PCon "TypeKey" (PVar "n") (PVar "o")) (PVar "args")) (EApp (EApp (EVar "foldTy") (ERecordCreate "TyCon" ((fa "tyConName" (EVar "n")) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "o"))))) (EVar "args")))
(DTypeSig false "foldTy" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "foldTy" ((PVar "t") (PList)) (EVar "t"))
(DFunDef false "foldTy" ((PVar "t") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "foldTy") (EApp (EApp (EVar "TyApp") (EVar "t")) (EVar "a"))) (EVar "rest")))
(DTypeSig false "planMany" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "GenPlan"))))))))
(DFunDef false "planMany" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "planMany" ((PVar "env") (PVar "propName") (PVar "param") (PCons (PVar "t") (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "planMany") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "p")) (PCon "Ok" (PVar "ps"))) () (EApp (EVar "Ok") (EBinOp "::" (EVar "p") (EVar "ps")))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "planDef" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "TypeKey") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanDef")))))
(DFunDef false "planDef" ((PCon "PlanEnv" PWild (PVar "defs") PWild PWild PWild) (PVar "key")) (EMatch (EApp (EApp (EVar "matchingDef") (EVar "key")) (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EApp (EVar "typeKeyWord") (EVar "key"))) (EVar "defs")))) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Ok") (EVar "d"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (ELit (LString ""))) (ELit (LString ""))) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EListLit))) (EVar "PEAmbiguousNominal")) (ELit (LString "")))))))
(DTypeSig true "instantiateCtor" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))))))))
(DFunDef false "instantiateCtor" ((PVar "env") (PCon "GNominal" (PVar "key") (PVar "args")) (PCon "PlanCtor" PWild PWild (PVar "fields"))) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild (PVar "params") PWild PWild)) () (EApp (EApp (EApp (EApp (EVar "instantiateFields") (EVar "env")) (EVar "params")) (EVar "args")) (EVar "fields"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DFunDef false "instantiateCtor" (PWild (PVar "p") PWild) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (ELit (LString ""))) (ELit (LString ""))) (EApp (EVar "TyVar") (ELit (LString "")))) (EVar "PEUnsupportedType")) (EBinOp "++" (ELit (LString "not nominal: ")) (EApp (EVar "planKind") (EVar "p"))))))
(DTypeSig true "customPlansReachable" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))
(DFunDef false "customPlansReachable" ((PVar "env") (PVar "plans")) (EApp (EVar "reverseCustomPlans") (EApp (EApp (EApp (EApp (EVar "customPlansGo") (EVar "env")) (EVar "plans")) (EVar "omEmpty")) (EListLit))))
(DTypeSig false "reverseCustomPlans" (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyApp (TyCon "List") (TyCon "CustomPlan"))))
(DFunDef false "reverseCustomPlans" ((PVar "plans")) (EApp (EApp (EVar "reverseCustomPlansGo") (EVar "plans")) (EListLit)))
(DTypeSig false "reverseCustomPlansGo" (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))
(DFunDef false "reverseCustomPlansGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseCustomPlansGo" ((PCons (PVar "plan") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "reverseCustomPlansGo") (EVar "rest")) (EBinOp "::" (EVar "plan") (EVar "acc"))))
(DTypeSig false "customPlansGo" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))))
(DFunDef false "customPlansGo" (PWild (PList) PWild (PVar "found")) (EVar "found"))
(DFunDef false "customPlansGo" ((PVar "env") (PCons (PVar "plan") (PVar "rest")) (PVar "seen") (PVar "found")) (EBlock (DoLet false false (PTuple (PVar "seen2") (PVar "found2")) (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (ELit (LInt 0))) (EVar "plan")) (EVar "seen")) (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "customPlansGo") (EVar "env")) (EVar "rest")) (EVar "seen2")) (EVar "found2")))))
(DTypeSig false "customPlansIn" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))))))
(DFunDef false "customPlansIn" ((PVar "env") (PVar "depth") (PVar "plan") (PVar "seen") (PVar "found")) (EBlock (DoLet false false (PVar "word") (EApp (EVar "arbCarrierWord") (EApp (EVar "planTy") (EVar "plan")))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "seen")) (ETuple (EVar "seen") (EVar "found")) (EBlock (DoLet false false (PVar "visited") (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EMatch (EVar "plan") (arm (PCon "GCustom" (PVar "custom")) () (ETuple (EVar "visited") (EBinOp "::" (EVar "custom") (EVar "found")))) (arm (PCon "GList" (PVar "item")) () (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "item")) (EVar "visited")) (EVar "found"))) (arm (PCon "GArray" (PVar "item")) () (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "item")) (EVar "visited")) (EVar "found"))) (arm (PCon "GOption" (PVar "item")) () (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "item")) (EVar "visited")) (EVar "found"))) (arm (PCon "GResult" (PVar "err") (PVar "ok")) () (EBlock (DoLet false false (PTuple (PVar "afterErr") (PVar "foundErr")) (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "err")) (EVar "visited")) (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "ok")) (EVar "afterErr")) (EVar "foundErr"))))) (arm (PCon "GTuple" (PVar "items")) () (EApp (EApp (EApp (EApp (EApp (EVar "customPlansState") (EVar "env")) (EVar "depth")) (EVar "items")) (EVar "visited")) (EVar "found"))) (arm (PAs "nominal" (PCon "GNominal" (PVar "key") PWild)) () (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "customPlansCtors") (EVar "env")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "nominal")) (EVar "ctors")) (EApp (EApp (EApp (EVar "ctorWeights") (EVar "env")) (EVar "nominal")) (EVar "depth"))) (EVar "visited")) (EVar "found"))) (arm (PCon "Err" PWild) () (ETuple (EVar "visited") (EVar "found"))))) (arm PWild () (ETuple (EVar "visited") (EVar "found"))))))))))
(DTypeSig false "customPlansState" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))))))
(DFunDef false "customPlansState" (PWild PWild (PList) (PVar "seen") (PVar "found")) (ETuple (EVar "seen") (EVar "found")))
(DFunDef false "customPlansState" ((PVar "env") (PVar "depth") (PCons (PVar "plan") (PVar "rest")) (PVar "seen") (PVar "found")) (EBlock (DoLet false false (PTuple (PVar "seen2") (PVar "found2")) (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "plan")) (EVar "seen")) (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "customPlansState") (EVar "env")) (EVar "depth")) (EVar "rest")) (EVar "seen2")) (EVar "found2")))))
(DTypeSig false "customPlansCtors" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))))))))
(DFunDef false "customPlansCtors" (PWild PWild PWild (PList) PWild (PVar "seen") (PVar "found")) (ETuple (EVar "seen") (EVar "found")))
(DFunDef false "customPlansCtors" (PWild PWild PWild PWild (PList) (PVar "seen") (PVar "found")) (ETuple (EVar "seen") (EVar "found")))
(DFunDef false "customPlansCtors" ((PVar "env") (PVar "depth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PCons (PVar "weight") (PVar "weights")) (PVar "seen") (PVar "found")) (EIf (EBinOp "<=" (EVar "weight") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "customPlansCtors") (EVar "env")) (EVar "depth")) (EVar "nominal")) (EVar "rest")) (EVar "weights")) (EVar "seen")) (EVar "found")) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EBlock (DoLet false false (PTuple (PVar "seen2") (PVar "found2")) (EApp (EApp (EApp (EApp (EApp (EVar "customPlansFields") (EVar "env")) (EVar "depth")) (EVar "fields")) (EVar "seen")) (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "customPlansCtors") (EVar "env")) (EVar "depth")) (EVar "nominal")) (EVar "rest")) (EVar "weights")) (EVar "seen2")) (EVar "found2"))))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "customPlansCtors") (EVar "env")) (EVar "depth")) (EVar "nominal")) (EVar "rest")) (EVar "weights")) (EVar "seen")) (EVar "found"))))))
(DTypeSig false "customPlansFields" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))))))
(DFunDef false "customPlansFields" (PWild PWild (PList) (PVar "seen") (PVar "found")) (ETuple (EVar "seen") (EVar "found")))
(DFunDef false "customPlansFields" ((PVar "env") (PVar "depth") (PCons (PTuple PWild (PVar "plan")) (PVar "rest")) (PVar "seen") (PVar "found")) (EBlock (DoLet false false (PTuple (PVar "seen2") (PVar "found2")) (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "plan")) (EVar "seen")) (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "customPlansFields") (EVar "env")) (EVar "depth")) (EVar "rest")) (EVar "seen2")) (EVar "found2")))))
(DTypeSig false "planKind" (TyFun (TyCon "GenPlan") (TyCon "String")))
(DFunDef false "planKind" ((PCon "GInt")) (ELit (LString "Int")))
(DFunDef false "planKind" ((PCon "GBool")) (ELit (LString "Bool")))
(DFunDef false "planKind" ((PCon "GFloat")) (ELit (LString "Float")))
(DFunDef false "planKind" ((PCon "GChar")) (ELit (LString "Char")))
(DFunDef false "planKind" ((PCon "GString")) (ELit (LString "String")))
(DFunDef false "planKind" ((PCon "GUnit")) (ELit (LString "Unit")))
(DFunDef false "planKind" (PWild) (ELit (LString "compound")))
(DTypeSig false "instantiateFields" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "PlanField")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan")))))))))
(DFunDef false "instantiateFields" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "instantiateFields" ((PVar "env") (PVar "params") (PVar "args") (PCons (PCon "PlanField" (PVar "name") (PVar "ty")) (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planTyWithPlans") (EVar "env")) (ELit (LString ""))) (EApp (EApp (EVar "zipL") (EVar "params")) (EVar "args"))) (EVar "ty")) (EApp (EApp (EApp (EApp (EVar "instantiateFields") (EVar "env")) (EVar "params")) (EVar "args")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "p")) (PCon "Ok" (PVar "ps"))) () (EApp (EVar "Ok") (EBinOp "::" (ETuple (EVar "name") (EVar "p")) (EVar "ps")))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "planTyWithPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "GenPlan"))) (TyFun (TyCon "Ty") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "GenPlan")))))))
(DFunDef false "planTyWithPlans" (PWild (PVar "param") (PVar "subst") (PCon "TyVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "subst")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "Ok") (EVar "p"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (ELit (LString ""))) (EVar "param")) (EApp (EVar "TyVar") (EVar "n"))) (EVar "PEUnboundTyVar")) (ELit (LString "")))))))
(DFunDef false "planTyWithPlans" ((PVar "env") (PVar "param") (PVar "subst") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (ELit (LString ""))) (EVar "param")) (EApp (EApp (EVar "substTy") (EVar "subst")) (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))))
(DFunDef false "planTyWithPlans" ((PVar "env") (PVar "param") (PVar "subst") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "map") (EVar "GTuple")) (EApp (EApp (EApp (EApp (EVar "planManySubst") (EVar "env")) (EVar "param")) (EVar "subst")) (EVar "ts"))))
(DFunDef false "planTyWithPlans" ((PVar "env") (PVar "param") (PVar "subst") (PVar "t")) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (ELit (LString ""))) (EVar "param")) (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "t"))))
(DTypeSig false "planManySubst" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "GenPlan"))))))))
(DFunDef false "planManySubst" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "planManySubst" ((PVar "env") (PVar "param") (PVar "subst") (PCons (PVar "t") (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planTyWithPlans") (EVar "env")) (EVar "param")) (EVar "subst")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "planManySubst") (EVar "env")) (EVar "param")) (EVar "subst")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "p")) (PCon "Ok" (PVar "ps"))) () (EApp (EVar "Ok") (EBinOp "::" (EVar "p") (EVar "ps")))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "substTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "GenPlan"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substTy" ((PVar "subst") (PVar "t")) (EApp (EApp (EVar "substTyRaw") (EApp (EApp (EVar "map") (EVar "planSubstPair")) (EVar "subst"))) (EVar "t")))
(DTypeSig false "planSubstPair" (TyFun (TyTuple (TyCon "String") (TyCon "GenPlan")) (TyTuple (TyCon "String") (TyCon "Ty"))))
(DFunDef false "planSubstPair" ((PTuple (PVar "n") (PVar "p"))) (ETuple (EVar "n") (EApp (EVar "planTy") (EVar "p"))))
(DTypeSig true "substTyRaw" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EApp (EVar "TyVar") (EVar "n")))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EVar "map") (EApp (EVar "substTyRaw") (EVar "subst"))) (EVar "ts"))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EApp (EApp (EApp (EVar "TyEffect") (EVar "es")) (EVar "tail")) (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "t"))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyNamed" (PVar "n") (PVar "t") (PVar "dom"))) (EApp (EApp (EApp (EVar "TyNamed") (EVar "n")) (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "t"))) (EVar "dom")))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyQual" (PVar "t") (PVar "qs") (PVar "loc"))) (EApp (EApp (EApp (EVar "TyQual") (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "t"))) (EVar "qs")) (EVar "loc")))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "t"))))
(DFunDef false "substTyRaw" (PWild (PVar "t")) (EVar "t"))
(DTypeSig true "planTy" (TyFun (TyCon "GenPlan") (TyCon "Ty")))
(DFunDef false "planTy" ((PCon "GInt")) (EApp (EVar "builtinTy") (ELit (LString "Int"))))
(DFunDef false "planTy" ((PCon "GBool")) (EApp (EVar "builtinTy") (ELit (LString "Bool"))))
(DFunDef false "planTy" ((PCon "GFloat")) (EApp (EVar "builtinTy") (ELit (LString "Float"))))
(DFunDef false "planTy" ((PCon "GChar")) (EApp (EVar "builtinTy") (ELit (LString "Char"))))
(DFunDef false "planTy" ((PCon "GString")) (EApp (EVar "builtinTy") (ELit (LString "String"))))
(DFunDef false "planTy" ((PCon "GUnit")) (EApp (EVar "builtinTy") (ELit (LString "Unit"))))
(DFunDef false "planTy" ((PCon "GList" (PVar "p"))) (EApp (EApp (EVar "TyApp") (EApp (EVar "builtinTy") (ELit (LString "List")))) (EApp (EVar "planTy") (EVar "p"))))
(DFunDef false "planTy" ((PCon "GArray" (PVar "p"))) (EApp (EApp (EVar "TyApp") (EApp (EVar "builtinTy") (ELit (LString "Array")))) (EApp (EVar "planTy") (EVar "p"))))
(DFunDef false "planTy" ((PCon "GOption" (PVar "p"))) (EApp (EApp (EVar "TyApp") (EApp (EVar "builtinTy") (ELit (LString "Option")))) (EApp (EVar "planTy") (EVar "p"))))
(DFunDef false "planTy" ((PCon "GResult" (PVar "e") (PVar "a"))) (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "TyApp") (EApp (EVar "builtinTy") (ELit (LString "Result")))) (EApp (EVar "planTy") (EVar "e")))) (EApp (EVar "planTy") (EVar "a"))))
(DFunDef false "planTy" ((PCon "GTuple" (PVar "ps"))) (EApp (EVar "TyTuple") (EApp (EApp (EVar "map") (EVar "planTy")) (EVar "ps"))))
(DFunDef false "planTy" ((PCon "GNominal" (PCon "TypeKey" (PVar "n") (PVar "o")) (PVar "ps"))) (EApp (EApp (EVar "foldTy") (ERecordCreate "TyCon" ((fa "tyConName" (EVar "n")) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "o"))))) (EApp (EApp (EVar "map") (EVar "planTy")) (EVar "ps"))))
(DFunDef false "planTy" ((PCon "GCustom" (PCon "CustomPlan" PWild (PVar "carrier") PWild))) (EVar "carrier"))
(DTypeSig false "builtinTy" (TyFun (TyCon "String") (TyCon "Ty")))
(DFunDef false "builtinTy" ((PVar "n")) (ERecordCreate "TyCon" ((fa "tyConName" (EVar "n")) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginBuiltin")))))
(DTypeSig true "intMin" (TyCon "Int"))
(DFunDef false "intMin" () (EUnOp "-" (ELit (LInt 1000))))
(DTypeSig true "intMax" (TyCon "Int"))
(DFunDef false "intMax" () (ELit (LInt 1000)))
(DTypeSig true "charMin" (TyCon "Int"))
(DFunDef false "charMin" () (ELit (LInt 32)))
(DTypeSig true "charMax" (TyCon "Int"))
(DFunDef false "charMax" () (ELit (LInt 126)))
(DTypeSig true "stringMaxLength" (TyCon "Int"))
(DFunDef false "stringMaxLength" () (ELit (LInt 10)))
(DTypeSig true "listLenMax" (TyCon "Int"))
(DFunDef false "listLenMax" () (ELit (LInt 7)))
(DTypeSig true "recWeight0" (TyCon "Int"))
(DFunDef false "recWeight0" () (ELit (LInt 6)))
(DTypeSig true "maxGenDepth" (TyCon "Int"))
(DFunDef false "maxGenDepth" () (ELit (LInt 24)))
(DTypeSig true "ctorWeights" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "ctorWeights" ((PVar "env") (PAs "nominal" (PCon "GNominal" PWild PWild)) (PVar "depth")) (EMatch (EApp (EApp (EVar "nominalCtors") (EVar "env")) (EVar "nominal")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EIf (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "boundCtorWeight") (EVar "env")) (EVar "nominal"))) (EVar "ctors")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "softCtorWeight") (EVar "env")) (EVar "nominal")) (EVar "depth"))) (EVar "ctors")))) (arm (PCon "Err" PWild) () (EListLit))))
(DFunDef false "ctorWeights" (PWild PWild PWild) (EListLit))
(DTypeSig false "nominalCtors" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanDef")))))
(DFunDef false "nominalCtors" ((PVar "env") (PCon "GNominal" (PVar "key") PWild)) (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")))
(DFunDef false "nominalCtors" (PWild (PVar "plan")) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (ELit (LString ""))) (ELit (LString ""))) (EApp (EVar "planTy") (EVar "plan"))) (EVar "PEUnsupportedType")) (ELit (LString "not a nominal plan")))))
(DData Public "SoftWeight" () ((variant "SoftNever" (ConPos)) (variant "SoftFixed" (ConPos (TyCon "Int"))) (variant "SoftDecaying" (ConPos (TyCon "Int")))) ())
(DTypeSig true "softCtorWeights" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyApp (TyCon "List") (TyCon "SoftWeight")))))
(DFunDef false "softCtorWeights" ((PVar "env") (PAs "nominal" (PCon "GNominal" PWild PWild))) (EMatch (EApp (EApp (EVar "nominalCtors") (EVar "env")) (EVar "nominal")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EVar "map") (EApp (EApp (EVar "softCtorWeightForm") (EVar "env")) (EVar "nominal"))) (EVar "ctors"))) (arm (PCon "Err" PWild) () (EListLit))))
(DFunDef false "softCtorWeights" (PWild PWild) (EListLit))
(DTypeSig false "softWeightAt" (TyFun (TyCon "Int") (TyFun (TyCon "SoftWeight") (TyCon "Int"))))
(DFunDef false "softWeightAt" (PWild (PCon "SoftNever")) (ELit (LInt 0)))
(DFunDef false "softWeightAt" (PWild (PCon "SoftFixed" (PVar "weight"))) (EVar "weight"))
(DFunDef false "softWeightAt" ((PVar "depth") (PCon "SoftDecaying" (PVar "start"))) (EApp (EApp (EVar "max") (ELit (LInt 1))) (EBinOp "-" (EVar "start") (EVar "depth"))))
(DTypeSig false "softCtorWeightForm" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyCon "SoftWeight")))))
(DFunDef false "softCtorWeightForm" ((PVar "env") (PVar "nominal") (PVar "ctor")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "ctorHasFiniteFields") (EVar "env")) (EVar "nominal")) (EVar "ctor"))) (EVar "SoftNever") (EIf (EApp (EApp (EApp (EVar "ctorCanDiverge") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (EApp (EVar "SoftDecaying") (EVar "recWeight0")) (EApp (EVar "SoftFixed") (EVar "recWeight0")))))
(DTypeSig false "softCtorWeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyFun (TyCon "PlanCtor") (TyCon "Int"))))))
(DFunDef false "softCtorWeight" ((PVar "env") (PVar "nominal") (PVar "depth") (PVar "ctor")) (EApp (EApp (EVar "softWeightAt") (EVar "depth")) (EApp (EApp (EApp (EVar "softCtorWeightForm") (EVar "env")) (EVar "nominal")) (EVar "ctor"))))
(DTypeSig false "ctorHasFiniteFields" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyCon "Bool")))))
(DFunDef false "ctorHasFiniteFields" ((PVar "env") (PVar "nominal") (PVar "ctor")) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EVar "allPlansFinite") (EVar "env")) (EApp (EVar "fieldPlansOnly") (EVar "fields")))) (arm (PCon "Err" PWild) () (EVar "False"))))
(DTypeSig false "ctorCanDiverge" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyCon "Bool")))))
(DFunDef false "ctorCanDiverge" ((PVar "env") (PVar "nominal") (PVar "ctor")) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EVar "anyPlanDiverges") (EVar "env")) (EApp (EVar "fieldPlansOnly") (EVar "fields")))) (arm (PCon "Err" PWild) () (EVar "False"))))
(DTypeSig false "boundCtorWeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyCon "Int")))))
(DFunDef false "boundCtorWeight" ((PVar "env") (PVar "nominal") (PVar "ctor")) (EIf (EApp (EApp (EApp (EVar "ctorLowersFiniteHeight") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (ELit (LInt 1)) (ELit (LInt 0))))
(DTypeSig false "ctorLowersFiniteHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyCon "Bool")))))
(DFunDef false "ctorLowersFiniteHeight" ((PVar "env") (PVar "nominal") (PVar "ctor")) (EMatch (ETuple (EApp (EApp (EApp (EVar "planFiniteHeight") (EVar "env")) (EVar "nominal")) (EListLit)) (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor"))) (arm (PTuple (PCon "Some" (PVar "height")) (PCon "Ok" (PVar "fields"))) () (EApp (EApp (EApp (EVar "allPlansBelow") (EVar "env")) (EVar "height")) (EApp (EVar "fieldPlansOnly") (EVar "fields")))) (arm PWild () (EVar "False"))))
(DTypeSig false "planHasFiniteValue" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Bool"))))
(DFunDef false "planHasFiniteValue" ((PVar "env") (PVar "plan")) (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "plan"))) (EVar "plan")))
(DTypeSig false "planFiniteHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "TypeKey")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "planFiniteHeight" ((PVar "env") (PVar "plan") PWild) (EBlock (DoLet false false (PVar "truth") (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "plan"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EVar "truth")) (EVar "plan")) (EApp (EApp (EApp (EApp (EVar "findFiniteHeight") (EVar "env")) (EVar "plan")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "finiteHeightLimit") (EVar "env")) (EVar "truth")) (EVar "plan"))) (EVar "None")))))
(DTypeSig false "finiteHeightLimit" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyCon "Int")))))
(DFunDef false "finiteHeightLimit" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" PWild (PVar "args")))) (EApp (EApp (EVar "max") (ELit (LInt 1))) (EBinOp "+" (EApp (EVar "omSize") (EApp (EApp (EApp (EVar "reachableStates") (EVar "env")) (EVar "truth")) (EVar "nominal"))) (EApp (EApp (EVar "greatestWitnessBound") (EVar "env")) (EVar "args")))))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GInt")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GBool")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GFloat")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GChar")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GString")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GUnit")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GList" PWild)) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GArray" PWild)) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GOption" PWild)) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" ((PVar "env") PWild (PCon "GResult" (PVar "err") (PVar "ok"))) (EApp (EApp (EVar "max") (EApp (EApp (EVar "witnessBound") (EVar "env")) (EVar "err"))) (EApp (EApp (EVar "witnessBound") (EVar "env")) (EVar "ok"))))
(DFunDef false "finiteHeightLimit" ((PVar "env") PWild (PCon "GTuple" (PVar "plans"))) (EApp (EApp (EVar "greatestWitnessBound") (EVar "env")) (EVar "plans")))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GCustom" PWild)) (ELit (LInt 0)))
(DTypeSig false "finiteTruth" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "finiteTruth" ((PVar "env") (PVar "root")) (EApp (EApp (EApp (EVar "finiteTruthLoop") (EVar "env")) (EVar "root")) (EVar "omEmpty")))
(DTypeSig false "finiteTruthLoop" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "finiteTruthLoop" ((PVar "env") (PVar "root") (PVar "truth")) (EBlock (DoLet false false (PVar "states") (EApp (EApp (EApp (EVar "reachableStates") (EVar "env")) (EVar "truth")) (EVar "root"))) (DoLet false false (PVar "next") (EApp (EApp (EApp (EApp (EVar "addFiniteStates") (EVar "env")) (EVar "truth")) (EVar "states")) (EVar "truth"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omSize") (EVar "next")) (EApp (EVar "omSize") (EVar "truth"))) (EVar "next") (EApp (EApp (EApp (EVar "finiteTruthLoop") (EVar "env")) (EVar "root")) (EVar "next"))))))
(DTypeSig false "addFiniteStates" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "addFiniteStates" ((PVar "env") (PVar "truth") (PVar "states") (PVar "result")) (EApp (EApp (EApp (EApp (EApp (EVar "addFiniteWords") (EVar "env")) (EVar "truth")) (EApp (EVar "omKeys") (EVar "states"))) (EVar "states")) (EVar "result")))
(DTypeSig false "addFiniteWords" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))
(DFunDef false "addFiniteWords" (PWild PWild (PList) PWild (PVar "result")) (EVar "result"))
(DFunDef false "addFiniteWords" ((PVar "env") (PVar "truth") (PCons (PVar "word") (PVar "rest")) (PVar "states") (PVar "result")) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "states")) (arm (PCon "Some" (PVar "state")) () (EIf (EApp (EApp (EApp (EVar "stateFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "state")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (ELit LUnit)) (EVar "result")) (EVar "result"))) (arm (PCon "None") () (EVar "result")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "addFiniteWords") (EVar "env")) (EVar "truth")) (EVar "rest")) (EVar "states")) (EVar "next")))))
(DTypeSig false "stateFiniteUnder" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyCon "Bool")))))
(DFunDef false "stateFiniteUnder" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild))) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EVar "anyCtorFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctors"))) (arm (PCon "Err" PWild) () (EVar "False"))))
(DFunDef false "stateFiniteUnder" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyCtorFiniteUnder" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyCon "Bool"))))))
(DFunDef false "anyCtorFiniteUnder" (PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyCtorFiniteUnder" ((PVar "env") (PVar "truth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EBinOp "||" (EApp (EApp (EApp (EVar "allFiniteUnder") (EVar "env")) (EVar "truth")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EApp (EApp (EApp (EApp (EVar "anyCtorFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EVar "anyCtorFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")))))
(DTypeSig false "allFiniteUnder" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool")))))
(DFunDef false "allFiniteUnder" (PWild PWild (PList)) (EVar "True"))
(DFunDef false "allFiniteUnder" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EVar "truth")) (EVar "plan")) (EApp (EApp (EApp (EVar "allFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "rest"))))
(DTypeSig false "abstractFinite" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyCon "Bool")))))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GInt")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GBool")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GFloat")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GChar")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GString")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GUnit")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GList" PWild)) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GArray" PWild)) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GOption" PWild)) (EVar "True"))
(DFunDef false "abstractFinite" ((PVar "env") (PVar "truth") (PCon "GResult" (PVar "err") (PVar "ok"))) (EBinOp "||" (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EVar "truth")) (EVar "err")) (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EVar "truth")) (EVar "ok"))))
(DFunDef false "abstractFinite" ((PVar "env") (PVar "truth") (PCon "GTuple" (PVar "plans"))) (EApp (EApp (EApp (EVar "allFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "plans")))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GCustom" PWild)) (EVar "True"))
(DFunDef false "abstractFinite" ((PVar "env") (PVar "truth") (PCon "GNominal" (PVar "key") (PVar "args"))) (EApp (EApp (EVar "omHasKey") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (EVar "truth")))
(DTypeSig false "reachableStates" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyApp (TyCon "OrdMap") (TyCon "GenPlan"))))))
(DFunDef false "reachableStates" ((PVar "env") (PVar "truth") (PVar "root")) (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EListLit (EVar "root"))) (EApp (EApp (EApp (EApp (EVar "seedArgumentStates") (EVar "env")) (EVar "truth")) (EVar "root")) (EVar "omEmpty"))))
(DTypeSig false "seedArgumentStates" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyApp (TyCon "OrdMap") (TyCon "GenPlan")))))))
(DFunDef false "seedArgumentStates" ((PVar "env") (PVar "truth") (PCon "GNominal" PWild (PVar "args")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlans") (EVar "env")) (EVar "truth")) (EVar "args")) (EVar "states")))
(DFunDef false "seedArgumentStates" (PWild PWild PWild (PVar "states")) (EVar "states"))
(DTypeSig false "seedPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyApp (TyCon "OrdMap") (TyCon "GenPlan")))))))
(DFunDef false "seedPlans" (PWild PWild (PList) (PVar "states")) (EVar "states"))
(DFunDef false "seedPlans" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlans") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "states"))))
(DTypeSig false "seedPlan" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyApp (TyCon "OrdMap") (TyCon "GenPlan")))))))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PCon "GList" (PVar "plan")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "states")))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PCon "GArray" (PVar "plan")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "states")))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PCon "GOption" (PVar "plan")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "states")))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "ok")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "err")) (EVar "states"))))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PCon "GTuple" (PVar "plans")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlans") (EVar "env")) (EVar "truth")) (EVar "plans")) (EVar "states")))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" (PVar "key") (PVar "args"))) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlans") (EVar "env")) (EVar "truth")) (EVar "args")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (EVar "nominal")) (EVar "states"))))
(DFunDef false "seedPlan" (PWild PWild PWild (PVar "states")) (EVar "states"))
(DTypeSig false "discoverStates" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyApp (TyCon "OrdMap") (TyCon "GenPlan")))))))
(DFunDef false "discoverStates" (PWild PWild (PList) (PVar "states")) (EVar "states"))
(DFunDef false "discoverStates" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest")) (PVar "states")) (EMatch (EVar "plan") (arm (PCon "GList" (PVar "child")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EBinOp "::" (EVar "child") (EVar "rest"))) (EVar "states"))) (arm (PCon "GArray" (PVar "child")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EBinOp "::" (EVar "child") (EVar "rest"))) (EVar "states"))) (arm (PCon "GOption" (PVar "child")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EBinOp "::" (EVar "child") (EVar "rest"))) (EVar "states"))) (arm (PCon "GResult" (PVar "err") (PVar "ok")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EListLit (EVar "err") (EVar "ok"))) (EVar "states")))) (arm (PCon "GTuple" (PVar "plans")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "plans")) (EVar "states")))) (arm (PAs "nominal" (PCon "GNominal" (PVar "key") (PVar "args"))) () (EBlock (DoLet false false (PVar "word") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "states")) (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "seedPlans") (EVar "env")) (EVar "truth")) (EVar "args")) (EVar "states"))) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "discoverCtorFields") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "nominal")) (EVar "states"))))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "nominal")) (EVar "states"))))))))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EVar "states")))))
(DTypeSig false "discoverCtorFields" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyApp (TyCon "OrdMap") (TyCon "GenPlan"))))))))
(DFunDef false "discoverCtorFields" (PWild PWild PWild (PList) (PVar "states")) (EVar "states"))
(DFunDef false "discoverCtorFields" ((PVar "env") (PVar "truth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PVar "states")) (EBlock (DoLet false false (PVar "afterCtor") (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EVar "states"))) (arm (PCon "Err" PWild) () (EVar "states")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "discoverCtorFields") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")) (EVar "afterCtor")))))
(DTypeSig false "stateWord" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "String"))))))
(DFunDef false "stateWord" ((PVar "env") (PVar "truth") (PVar "key") (PVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "typeKeyWord") (EVar "key")))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "stateBits") (EVar "env")) (EVar "truth")) (EVar "args")))) (ELit (LString ""))))
(DTypeSig false "stateBits" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "String")))))
(DFunDef false "stateBits" (PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "stateBits" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest"))) (EBinOp "++" (EIf (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EVar "truth")) (EVar "plan")) (ELit (LString "1")) (ELit (LString "0"))) (EApp (EApp (EApp (EVar "stateBits") (EVar "env")) (EVar "truth")) (EVar "rest"))))
(DTypeSig false "greatestWitnessBound" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Int"))))
(DFunDef false "greatestWitnessBound" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "greatestWitnessBound" ((PVar "env") (PCons (PVar "plan") (PVar "rest"))) (EApp (EApp (EVar "max") (EApp (EApp (EVar "witnessBound") (EVar "env")) (EVar "plan"))) (EApp (EApp (EVar "greatestWitnessBound") (EVar "env")) (EVar "rest"))))
(DTypeSig false "witnessBound" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Int"))))
(DFunDef false "witnessBound" (PWild (PCon "GInt")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GBool")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GFloat")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GChar")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GString")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GUnit")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GList" PWild)) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GArray" PWild)) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GOption" PWild)) (ELit (LInt 0)))
(DFunDef false "witnessBound" ((PVar "env") (PCon "GResult" (PVar "err") (PVar "ok"))) (EApp (EApp (EVar "max") (EApp (EApp (EVar "witnessBound") (EVar "env")) (EVar "err"))) (EApp (EApp (EVar "witnessBound") (EVar "env")) (EVar "ok"))))
(DFunDef false "witnessBound" ((PVar "env") (PCon "GTuple" (PVar "plans"))) (EApp (EApp (EVar "greatestWitnessBound") (EVar "env")) (EVar "plans")))
(DFunDef false "witnessBound" ((PVar "env") (PAs "nominal" (PCon "GNominal" PWild (PVar "args")))) (EBinOp "+" (EApp (EVar "omSize") (EApp (EApp (EApp (EVar "reachableStates") (EVar "env")) (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "nominal"))) (EVar "nominal"))) (EApp (EApp (EVar "greatestWitnessBound") (EVar "env")) (EVar "args"))))
(DFunDef false "witnessBound" (PWild (PCon "GCustom" PWild)) (ELit (LInt 0)))
(DTypeSig false "findFiniteHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "findFiniteHeight" (PWild PWild (PVar "height") (PVar "limit")) (EIf (EBinOp ">" (EVar "height") (EVar "limit")) (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "findFiniteHeight" ((PVar "env") (PVar "plan") (PVar "height") (PVar "limit")) (EIf (EApp (EApp (EApp (EVar "planFitsHeight") (EVar "env")) (EVar "plan")) (EVar "height")) (EApp (EVar "Some") (EVar "height")) (EApp (EApp (EApp (EApp (EVar "findFiniteHeight") (EVar "env")) (EVar "plan")) (EBinOp "+" (EVar "height") (ELit (LInt 1)))) (EVar "limit"))))
(DTypeSig false "planFitsHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "planFitsHeight" (PWild PWild (PVar "height")) (EIf (EBinOp "<" (EVar "height") (ELit (LInt 0))) (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planFitsHeight" (PWild (PCon "GInt") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GBool") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GFloat") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GChar") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GString") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GUnit") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GList" PWild) PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GArray" PWild) PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GOption" PWild) PWild) (EVar "True"))
(DFunDef false "planFitsHeight" ((PVar "env") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "height")) (EBinOp "||" (EApp (EApp (EApp (EVar "planFitsHeight") (EVar "env")) (EVar "err")) (EVar "height")) (EApp (EApp (EApp (EVar "planFitsHeight") (EVar "env")) (EVar "ok")) (EVar "height"))))
(DFunDef false "planFitsHeight" ((PVar "env") (PCon "GTuple" (PVar "plans")) (PVar "height")) (EApp (EApp (EApp (EVar "allPlansFitHeight") (EVar "env")) (EVar "plans")) (EVar "height")))
(DFunDef false "planFitsHeight" (PWild (PCon "GCustom" PWild) PWild) (EVar "True"))
(DFunDef false "planFitsHeight" ((PVar "env") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild)) (PVar "height")) (EIf (EBinOp "<=" (EVar "height") (ELit (LInt 0))) (EVar "False") (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EVar "anyCtorFitsHeight") (EVar "env")) (EVar "nominal")) (EVar "ctors")) (EBinOp "-" (EVar "height") (ELit (LInt 1))))) (arm (PCon "Err" PWild) () (EVar "False")))))
(DTypeSig false "anyCtorFitsHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "anyCtorFitsHeight" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyCtorFitsHeight" ((PVar "env") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PVar "height")) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EBinOp "||" (EApp (EApp (EApp (EVar "allPlansFitHeight") (EVar "env")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EVar "height")) (EApp (EApp (EApp (EApp (EVar "anyCtorFitsHeight") (EVar "env")) (EVar "nominal")) (EVar "rest")) (EVar "height")))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EVar "anyCtorFitsHeight") (EVar "env")) (EVar "nominal")) (EVar "rest")) (EVar "height")))))
(DTypeSig false "allPlansFitHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allPlansFitHeight" (PWild (PList) PWild) (EVar "True"))
(DFunDef false "allPlansFitHeight" ((PVar "env") (PCons (PVar "plan") (PVar "rest")) (PVar "height")) (EBinOp "&&" (EApp (EApp (EApp (EVar "planFitsHeight") (EVar "env")) (EVar "plan")) (EVar "height")) (EApp (EApp (EApp (EVar "allPlansFitHeight") (EVar "env")) (EVar "rest")) (EVar "height"))))
(DTypeSig false "allPlansFinite" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool"))))
(DFunDef false "allPlansFinite" (PWild (PList)) (EVar "True"))
(DFunDef false "allPlansFinite" ((PVar "env") (PCons (PVar "plan") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan")) (EApp (EApp (EVar "allPlansFinite") (EVar "env")) (EVar "rest"))))
(DTypeSig false "fieldPlansOnly" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyApp (TyCon "List") (TyCon "GenPlan"))))
(DFunDef false "fieldPlansOnly" ((PList)) (EListLit))
(DFunDef false "fieldPlansOnly" ((PCons (PTuple PWild (PVar "plan")) (PVar "rest"))) (EBinOp "::" (EVar "plan") (EApp (EVar "fieldPlansOnly") (EVar "rest"))))
(DTypeSig false "allPlansBelow" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool")))))
(DFunDef false "allPlansBelow" (PWild PWild (PList)) (EVar "True"))
(DFunDef false "allPlansBelow" ((PVar "env") (PVar "height") (PCons (PVar "plan") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "planFiniteHeight") (EVar "env")) (EVar "plan")) (EListLit)) (arm (PCon "Some" (PVar "planHeight")) () (EBinOp "&&" (EBinOp "<" (EVar "planHeight") (EVar "height")) (EApp (EApp (EApp (EVar "allPlansBelow") (EVar "env")) (EVar "height")) (EVar "rest")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "planFor" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "GenPlan")))))))
(DFunDef false "planFor" ((PVar "env") (PVar "propName") (PVar "param") (PVar "ty")) (EMatch (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "ty")) (arm (PCon "Ok" (PVar "plan")) () (EMatch (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "plan"))) (EVar "plan")) (EVar "omEmpty")) (arm (PCon "Err" (PCon "PlanError" PWild PWild (PVar "badTy") (PVar "reason") (PVar "detail"))) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "badTy")) (EVar "reason")) (EVar "detail")))) (arm (PCon "Ok" PWild) () (EIf (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan")) (EApp (EVar "Ok") (EVar "plan")) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "ty")) (EVar "PENoFiniteValue")) (ELit (LString "no constructor path reaches finite values")))))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "validateReachableFields" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "Unit")))))))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GInt") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GBool") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GFloat") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GChar") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GString") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GUnit") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PCon "GList" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PCon "GArray" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PCon "GOption" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "seen")) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "err")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "ok")) (EVar "seen"))) (arm (PTuple (PCon "Ok" PWild) (PCon "Ok" PWild)) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PCon "GTuple" (PVar "plans")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachablePlans") (EVar "env")) (EVar "truth")) (EVar "plans")) (EVar "seen")))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GCustom" PWild) PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" (PVar "key") (PVar "args"))) (PVar "seen")) (EBlock (DoLet false false (PVar "word") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "seen")) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EApp (EVar "validateReachableCtors") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (ELit LUnit)) (EVar "seen")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))))))))
(DTypeSig false "validateReachablePlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "Unit")))))))
(DFunDef false "validateReachablePlans" (PWild PWild (PList) PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachablePlans" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest")) (PVar "seen")) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachablePlans") (EVar "env")) (EVar "truth")) (EVar "rest")) (EVar "seen"))) (arm (PTuple (PCon "Ok" PWild) (PCon "Ok" PWild)) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "validateReachableCtors" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "Unit"))))))))
(DFunDef false "validateReachableCtors" (PWild PWild PWild (PList) PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableCtors" ((PVar "env") (PVar "truth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PVar "seen")) (EMatch (ETuple (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (EApp (EApp (EApp (EApp (EApp (EVar "validateReachableCtors") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")) (EVar "seen"))) (arm (PTuple (PCon "Ok" (PVar "fields")) (PCon "Ok" PWild)) () (EApp (EApp (EApp (EApp (EVar "validateReachablePlans") (EVar "env")) (EVar "truth")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EVar "seen"))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "listLengthBound" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyCon "Int")))))
(DFunDef false "listLengthBound" ((PVar "env") (PVar "depth") (PVar "plan")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan"))) (ELit (LInt 0)) (EIf (EApp (EApp (EVar "planCyclesThroughList") (EVar "env")) (EVar "plan")) (EApp (EApp (EVar "max") (ELit (LInt 0))) (EBinOp "-" (EVar "listLenMax") (EVar "depth"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "plan"))) (ELit (LInt 0)) (EVar "listLenMax")))))
(DTypeSig true "listBoundDecays" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Bool"))))
(DFunDef false "listBoundDecays" ((PVar "env") (PVar "plan")) (EBinOp "&&" (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan")) (EApp (EApp (EVar "planCyclesThroughList") (EVar "env")) (EVar "plan"))))
(DTypeSig true "planCyclesThroughList" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Bool"))))
(DFunDef false "planCyclesThroughList" ((PVar "env") (PVar "plan")) (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "plan"))) (EVar "plan")) (EVar "omEmpty")) (ELit (LInt 0))))
(DTypeSig false "cyclesThroughListIn" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PCon "GList" (PVar "p")) (PVar "seen") (PVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "p")) (EVar "seen")) (EBinOp "+" (EVar "lists") (ELit (LInt 1)))))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PCon "GArray" (PVar "p")) (PVar "seen") (PVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "p")) (EVar "seen")) (EBinOp "+" (EVar "lists") (ELit (LInt 1)))))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PCon "GOption" (PVar "p")) (PVar "seen") (PVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "p")) (EVar "seen")) (EVar "lists")))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "seen") (PVar "lists")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "err")) (EVar "seen")) (EVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "ok")) (EVar "seen")) (EVar "lists"))))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PCon "GTuple" (PVar "ps")) (PVar "seen") (PVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "anyCyclesThroughList") (EVar "env")) (EVar "truth")) (EVar "ps")) (EVar "seen")) (EVar "lists")))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" (PVar "key") (PVar "args"))) (PVar "seen") (PVar "lists")) (EBlock (DoLet false false (PVar "word") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "seen")) (arm (PCon "Some" (PVar "entered")) () (EBinOp ">" (EVar "lists") (EVar "entered"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "anyCtorCyclesThroughList") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "lists")) (EVar "seen"))) (EVar "lists"))) (arm (PCon "Err" PWild) () (EVar "False"))))))))
(DFunDef false "cyclesThroughListIn" (PWild PWild PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyCyclesThroughList" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "anyCyclesThroughList" (PWild PWild (PList) PWild PWild) (EVar "False"))
(DFunDef false "anyCyclesThroughList" ((PVar "env") (PVar "truth") (PCons (PVar "p") (PVar "ps")) (PVar "seen") (PVar "lists")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "p")) (EVar "seen")) (EVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "anyCyclesThroughList") (EVar "env")) (EVar "truth")) (EVar "ps")) (EVar "seen")) (EVar "lists"))))
(DTypeSig false "anyCtorCyclesThroughList" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "anyCtorCyclesThroughList" (PWild PWild PWild (PList) PWild PWild) (EVar "False"))
(DFunDef false "anyCtorCyclesThroughList" ((PVar "env") (PVar "truth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PVar "seen") (PVar "lists")) (EBinOp "||" (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EApp (EVar "anyCyclesThroughList") (EVar "env")) (EVar "truth")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EVar "seen")) (EVar "lists"))) (arm (PCon "Err" PWild) () (EVar "False"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "anyCtorCyclesThroughList") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")) (EVar "seen")) (EVar "lists"))))
(DTypeSig true "optionWeights" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "optionWeights" ((PVar "env") (PVar "depth") (PVar "plan")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan"))) (EListLit (ELit (LInt 1)) (ELit (LInt 0))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "plan"))) (EListLit (ELit (LInt 1)) (ELit (LInt 0))) (EListLit (ELit (LInt 1)) (ELit (LInt 1))))))
(DTypeSig true "resultWeights" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyCon "GenPlan") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "resultWeights" ((PVar "env") (PVar "depth") (PVar "err") (PVar "ok")) (EIf (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (EListLit (EApp (EApp (EVar "boundPlanWeight") (EVar "env")) (EVar "err")) (EApp (EApp (EVar "boundPlanWeight") (EVar "env")) (EVar "ok"))) (EListLit (EApp (EApp (EVar "finitePlanWeight") (EVar "env")) (EVar "err")) (EApp (EApp (EVar "finitePlanWeight") (EVar "env")) (EVar "ok")))))
(DTypeSig false "finitePlanWeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Int"))))
(DFunDef false "finitePlanWeight" ((PVar "env") (PVar "plan")) (EIf (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan")) (ELit (LInt 1)) (ELit (LInt 0))))
(DTypeSig false "boundPlanWeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Int"))))
(DFunDef false "boundPlanWeight" ((PVar "env") (PVar "plan")) (EIf (EApp (EApp (EVar "planCanFinishAtBound") (EVar "env")) (EVar "plan")) (ELit (LInt 1)) (ELit (LInt 0))))
(DTypeSig false "planCanFinishAtBound" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Bool"))))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GInt")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GBool")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GFloat")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GChar")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GString")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GUnit")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GList" PWild)) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GArray" PWild)) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GOption" PWild)) (EVar "True"))
(DFunDef false "planCanFinishAtBound" ((PVar "env") (PCon "GResult" (PVar "err") (PVar "ok"))) (EBinOp "||" (EApp (EApp (EVar "planCanFinishAtBound") (EVar "env")) (EVar "err")) (EApp (EApp (EVar "planCanFinishAtBound") (EVar "env")) (EVar "ok"))))
(DFunDef false "planCanFinishAtBound" ((PVar "env") (PCon "GTuple" (PVar "plans"))) (EApp (EApp (EVar "allPlansFinishAtBound") (EVar "env")) (EVar "plans")))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GCustom" PWild)) (EVar "True"))
(DFunDef false "planCanFinishAtBound" ((PVar "env") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild))) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EVar "anyBoundCtor") (EVar "env")) (EVar "nominal")) (EVar "ctors"))) (arm (PCon "Err" PWild) () (EVar "False"))))
(DTypeSig false "anyBoundCtor" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyCon "Bool")))))
(DFunDef false "anyBoundCtor" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyBoundCtor" ((PVar "env") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "ctorLowersFiniteHeight") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (EApp (EApp (EApp (EVar "anyBoundCtor") (EVar "env")) (EVar "nominal")) (EVar "rest"))))
(DTypeSig false "allPlansFinishAtBound" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool"))))
(DFunDef false "allPlansFinishAtBound" (PWild (PList)) (EVar "True"))
(DFunDef false "allPlansFinishAtBound" ((PVar "env") (PCons (PVar "plan") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "planCanFinishAtBound") (EVar "env")) (EVar "plan")) (EApp (EApp (EVar "allPlansFinishAtBound") (EVar "env")) (EVar "rest"))))
(DTypeSig true "planCanDiverge" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Bool"))))
(DFunDef false "planCanDiverge" (PWild (PCon "GInt")) (EVar "False"))
(DFunDef false "planCanDiverge" (PWild (PCon "GBool")) (EVar "False"))
(DFunDef false "planCanDiverge" (PWild (PCon "GFloat")) (EVar "False"))
(DFunDef false "planCanDiverge" (PWild (PCon "GChar")) (EVar "False"))
(DFunDef false "planCanDiverge" (PWild (PCon "GString")) (EVar "False"))
(DFunDef false "planCanDiverge" (PWild (PCon "GUnit")) (EVar "False"))
(DFunDef false "planCanDiverge" ((PVar "env") (PCon "GList" (PVar "p"))) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "p")))
(DFunDef false "planCanDiverge" ((PVar "env") (PCon "GArray" (PVar "p"))) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "p")))
(DFunDef false "planCanDiverge" ((PVar "env") (PCon "GOption" (PVar "p"))) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "p")))
(DFunDef false "planCanDiverge" ((PVar "env") (PCon "GResult" (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "a")) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "b"))))
(DFunDef false "planCanDiverge" ((PVar "env") (PCon "GTuple" (PVar "ps"))) (EApp (EApp (EVar "anyPlanDiverges") (EVar "env")) (EVar "ps")))
(DFunDef false "planCanDiverge" ((PVar "env") (PAs "nominal" (PCon "GNominal" PWild PWild))) (EApp (EApp (EApp (EApp (EVar "planCanDivergeNominal") (EVar "env")) (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "nominal"))) (EVar "nominal")) (EVar "omEmpty")))
(DFunDef false "planCanDiverge" (PWild (PCon "GCustom" PWild)) (EVar "False"))
(DTypeSig false "anyPlanDiverges" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool"))))
(DFunDef false "anyPlanDiverges" (PWild (PList)) (EVar "False"))
(DFunDef false "anyPlanDiverges" ((PVar "env") (PCons (PVar "p") (PVar "ps"))) (EBinOp "||" (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "p")) (EApp (EApp (EVar "anyPlanDiverges") (EVar "env")) (EVar "ps"))))
(DTypeSig false "planCanDivergeNominal" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool"))))))
(DFunDef false "planCanDivergeNominal" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" (PVar "key") (PVar "args"))) (PVar "seen")) (EBlock (DoLet false false (PVar "word") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "seen")) (EVar "True") (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EApp (EVar "anyCtorPlanDiverges") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (ELit LUnit)) (EVar "seen")))) (arm (PCon "Err" PWild) () (EVar "False")))))))
(DFunDef false "planCanDivergeNominal" (PWild PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyCtorPlanDiverges" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool")))))))
(DFunDef false "anyCtorPlanDiverges" (PWild PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyCtorPlanDiverges" ((PVar "env") (PVar "truth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PVar "seen")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "ctorPlanDiverges") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctor")) (EVar "seen")) (EApp (EApp (EApp (EApp (EApp (EVar "anyCtorPlanDiverges") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")) (EVar "seen"))))
(DTypeSig false "ctorPlanDiverges" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool")))))))
(DFunDef false "ctorPlanDiverges" ((PVar "env") (PVar "truth") (PVar "nominal") (PVar "ctor") (PVar "seen")) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "anyPlansDivergeSeen") (EVar "env")) (EVar "truth")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EVar "seen"))) (arm (PCon "Err" PWild) () (EVar "False"))))
(DTypeSig false "anyPlansDivergeSeen" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool"))))))
(DFunDef false "anyPlansDivergeSeen" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyPlansDivergeSeen" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest")) (PVar "seen")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "anyPlansDivergeSeen") (EVar "env")) (EVar "truth")) (EVar "rest")) (EVar "seen"))))
(DTypeSig false "planDivergesSeen" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool"))))))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GInt") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GBool") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GFloat") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GChar") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GString") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GUnit") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PCon "GList" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PCon "GArray" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PCon "GOption" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "seen")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "err")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "ok")) (EVar "seen"))))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PCon "GTuple" (PVar "plans")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "anyPlansDivergeSeen") (EVar "env")) (EVar "truth")) (EVar "plans")) (EVar "seen")))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" PWild PWild)) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "planCanDivergeNominal") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "seen")))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GCustom" PWild) PWild) (EVar "False"))
(DData Public "ShrinkAction" () ((variant "DeleteElements" (ConPos)) (variant "ShrinkChildren" (ConPos)) (variant "ReplaceEarlierNullary" (ConPos))) ())
(DTypeSig true "shrinkActions" (TyFun (TyCon "GenPlan") (TyApp (TyCon "List") (TyCon "ShrinkAction"))))
(DFunDef false "shrinkActions" ((PCon "GList" PWild)) (EListLit (EVar "DeleteElements") (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" ((PCon "GArray" PWild)) (EListLit (EVar "DeleteElements") (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" ((PCon "GTuple" PWild)) (EListLit (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" ((PCon "GOption" PWild)) (EListLit (EVar "ReplaceEarlierNullary") (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" ((PCon "GResult" PWild PWild)) (EListLit (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" ((PCon "GNominal" PWild PWild)) (EListLit (EVar "ReplaceEarlierNullary") (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" (PWild) (EListLit))
(DData Public "IntShrinkStep" () ((variant "IntToZero" (ConPos)) (variant "IntHalf" (ConPos)) (variant "IntTowardZero" (ConPos))) ())
(DTypeSig true "intShrinkSteps" (TyApp (TyCon "List") (TyCon "IntShrinkStep")))
(DFunDef false "intShrinkSteps" () (EListLit (EVar "IntToZero") (EVar "IntHalf") (EVar "IntTowardZero")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "DataVis" true) (mem "Variant" true) (mem "Field" true) (mem "ConPayload" true) (mem "ImplMethod" true) (mem "sameTyConHead" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "typeTagOf" false) (mem "implRouteKeyWord" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false) (mem "omSize" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "zipL" false))))
(DTypeSig true "structuralRngModulus" (TyCon "Int"))
(DFunDef false "structuralRngModulus" () (ELit (LInt 2147483648)))
(DTypeSig true "structuralRngMultiplier" (TyCon "Int"))
(DFunDef false "structuralRngMultiplier" () (ELit (LInt 1103515245)))
(DTypeSig true "structuralRngIncrement" (TyCon "Int"))
(DFunDef false "structuralRngIncrement" () (ELit (LInt 12345)))
(DTypeSig true "structuralRngMixMultiplier1" (TyCon "Int"))
(DFunDef false "structuralRngMixMultiplier1" () (ELit (LInt 2246822507)))
(DTypeSig true "structuralRngMixMultiplier2" (TyCon "Int"))
(DFunDef false "structuralRngMixMultiplier2" () (ELit (LInt 3266489909)))
(DTypeSig true "structuralRngWordModulus" (TyCon "Int"))
(DFunDef false "structuralRngWordModulus" () (ELit (LInt 4294967296)))
(DTypeSig true "structuralRngWordHalf" (TyCon "Int"))
(DFunDef false "structuralRngWordHalf" () (ELit (LInt 65536)))
(DTypeSig true "structuralRngSeed" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "structuralRngSeed" ((PVar "n")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (EVar "structuralRngModulus")) (EVar "structuralRngModulus")) (EVar "structuralRngModulus")))
(DTypeSig true "structuralRngAdvance" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "structuralRngAdvance" ((PVar "state")) (EBinOp "%" (EBinOp "+" (EBinOp "*" (EVar "state") (EVar "structuralRngMultiplier")) (EVar "structuralRngIncrement")) (EVar "structuralRngModulus")))
(DTypeSig false "structuralRngWord" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "structuralRngWord" ((PVar "n")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (EVar "structuralRngWordModulus")) (EVar "structuralRngWordModulus")) (EVar "structuralRngWordModulus")))
(DTypeSig false "structuralRngMulWord" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "structuralRngMulWord" ((PVar "left") (PVar "right")) (EBlock (DoLet false false (PVar "x") (EApp (EVar "structuralRngWord") (EVar "left"))) (DoLet false false (PVar "y") (EApp (EVar "structuralRngWord") (EVar "right"))) (DoLet false false (PVar "xLow") (EBinOp "%" (EVar "x") (EVar "structuralRngWordHalf"))) (DoLet false false (PVar "xHigh") (EBinOp "/" (EVar "x") (EVar "structuralRngWordHalf"))) (DoLet false false (PVar "yLow") (EBinOp "%" (EVar "y") (EVar "structuralRngWordHalf"))) (DoLet false false (PVar "yHigh") (EBinOp "/" (EVar "y") (EVar "structuralRngWordHalf"))) (DoLet false false (PVar "low") (EBinOp "*" (EVar "xLow") (EVar "yLow"))) (DoLet false false (PVar "cross") (EBinOp "+" (EBinOp "*" (EVar "xLow") (EVar "yHigh")) (EBinOp "*" (EVar "xHigh") (EVar "yLow")))) (DoExpr (EApp (EVar "structuralRngWord") (EBinOp "+" (EVar "low") (EBinOp "*" (EBinOp "%" (EVar "cross") (EVar "structuralRngWordHalf")) (EVar "structuralRngWordHalf")))))))
(DTypeSig true "structuralRngMix" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "structuralRngMix" ((PVar "state")) (EBlock (DoLet false false (PVar "word") (EApp (EVar "structuralRngWord") (EVar "state"))) (DoLet false false (PVar "h1") (EApp (EVar "structuralRngWord") (EApp (EApp (EVar "bitXor") (EVar "word")) (EApp (EApp (EVar "shiftRight") (EVar "word")) (ELit (LInt 16)))))) (DoLet false false (PVar "h2") (EApp (EApp (EVar "structuralRngMulWord") (EVar "h1")) (EVar "structuralRngMixMultiplier1"))) (DoLet false false (PVar "h3") (EApp (EVar "structuralRngWord") (EApp (EApp (EVar "bitXor") (EVar "h2")) (EApp (EApp (EVar "shiftRight") (EVar "h2")) (ELit (LInt 13)))))) (DoLet false false (PVar "h4") (EApp (EApp (EVar "structuralRngMulWord") (EVar "h3")) (EVar "structuralRngMixMultiplier2"))) (DoExpr (EApp (EVar "structuralRngWord") (EApp (EApp (EVar "bitXor") (EVar "h4")) (EApp (EApp (EVar "shiftRight") (EVar "h4")) (ELit (LInt 16))))))))
(DTypeSig true "structuralRngRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "structuralRngRange" ((PVar "word") (PVar "lo") (PVar "hi")) (EBlock (DoLet false false (PVar "width") (EBinOp "+" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<=" (EVar "width") (ELit (LInt 0))) (EVar "lo") (EBinOp "+" (EVar "lo") (EBinOp "%" (EVar "word") (EVar "width")))))))
(DTypeSig true "structuralRngChoose" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "structuralRngChoose" ((PVar "word") (PVar "width")) (EIf (EBinOp "<=" (EVar "width") (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "%" (EVar "word") (EVar "width"))))
(DTypeSig true "deleteEach" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "deleteEach" ((PList)) (EListLit))
(DFunDef false "deleteEach" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "xs") (EApp (EApp (EMethodRef "map") (EApp (EVar "prepend") (EVar "x"))) (EApp (EVar "deleteEach") (EVar "xs")))))
(DTypeSig true "prepend" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "prepend" ((PVar "x") (PVar "xs")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DTypeSig true "replaceEach" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "replaceEach" (PWild (PList)) (EListLit))
(DFunDef false "replaceEach" ((PVar "smaller") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "prependBefore") (EVar "xs"))) (EApp (EVar "smaller") (EVar "x"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "prepend") (EVar "x"))) (EApp (EApp (EVar "replaceEach") (EVar "smaller")) (EVar "xs")))))
(DTypeSig true "prependBefore" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "prependBefore" ((PVar "xs") (PVar "x")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DData Public "TypeKey" () ((variant "TypeKey" (ConPos (TyCon "String") (TyCon "TyConOrigin")))) ())
(DTypeSig true "typeKeyWord" (TyFun (TyCon "TypeKey") (TyCon "String")))
(DFunDef false "typeKeyWord" ((PCon "TypeKey" (PVar "n") (PVar "o"))) (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n")))
(DTypeSig false "sameTypeKey" (TyFun (TyCon "TypeKey") (TyFun (TyCon "TypeKey") (TyCon "Bool"))))
(DFunDef false "sameTypeKey" ((PCon "TypeKey" (PVar "n") (PVar "o")) (PCon "TypeKey" (PVar "n2") (PVar "o2"))) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "n")) (EVar "o")) (EVar "n2")) (EVar "o2")))
(DData Public "PlanVisibility" () ((variant "PlanLocal" (ConPos)) (variant "PlanPublicCtors" (ConPos)) (variant "PlanAbstract" (ConPos))) ())
(DData Public "PlanField" () ((variant "PlanField" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Ty")))) ())
(DData Public "PlanCtor" () ((variant "PlanCtor" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "PlanField"))))) ())
(DData Public "PlanDef" () ((variant "PlanDef" (ConPos (TyCon "TypeKey") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyCon "PlanVisibility") (TyApp (TyCon "List") (TyCon "PlanCtor"))))) ())
(DData Public "CustomPlan" () ((variant "CustomPlan" (ConPos (TyCon "TypeKey") (TyCon "Ty") (TyCon "String")))) ())
(DData Public "GenPlan" () ((variant "GInt" (ConPos)) (variant "GBool" (ConPos)) (variant "GFloat" (ConPos)) (variant "GChar" (ConPos)) (variant "GString" (ConPos)) (variant "GUnit" (ConPos)) (variant "GList" (ConPos (TyCon "GenPlan"))) (variant "GArray" (ConPos (TyCon "GenPlan"))) (variant "GOption" (ConPos (TyCon "GenPlan"))) (variant "GResult" (ConPos (TyCon "GenPlan") (TyCon "GenPlan"))) (variant "GTuple" (ConPos (TyApp (TyCon "List") (TyCon "GenPlan")))) (variant "GNominal" (ConPos (TyCon "TypeKey") (TyApp (TyCon "List") (TyCon "GenPlan")))) (variant "GCustom" (ConPos (TyCon "CustomPlan")))) ())
(DData Public "PlanErrorReason" () ((variant "PEUnboundTyVar" (ConPos)) (variant "PETypeAlias" (ConPos)) (variant "PEFunction" (ConPos)) (variant "PEUnsupportedType" (ConPos)) (variant "PEOpaqueNominal" (ConPos)) (variant "PEAmbiguousNominal" (ConPos)) (variant "PENoFiniteValue" (ConPos)) (variant "PEUnusableArbitrary" (ConPos)) (variant "PEInaccessibleConstructors" (ConPos))) ())
(DData Public "PlanError" () ((variant "PlanError" (ConPos (TyCon "String") (TyCon "String") (TyCon "Ty") (TyCon "PlanErrorReason") (TyCon "String")))) ())
(DTypeSig true "planErrorText" (TyFun (TyCon "PlanError") (TyCon "String")))
(DFunDef false "planErrorText" ((PCon "PlanError" (PVar "propName") (PVar "name") PWild (PVar "reason") (PVar "detail"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "property '")) (EApp (EMethodRef "display") (EVar "propName"))) (ELit (LString "', parameter '"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' cannot be generated: "))) (EApp (EMethodRef "display") (EApp (EVar "reasonText") (EVar "reason")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EIf (EBinOp "==" (EVar "detail") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EVar "detail")) (ELit (LString ")")))))) (ELit (LString ""))))
(DTypeSig false "reasonText" (TyFun (TyCon "PlanErrorReason") (TyCon "String")))
(DFunDef false "reasonText" ((PCon "PEUnboundTyVar")) (ELit (LString "unbound type variable")))
(DFunDef false "reasonText" ((PCon "PETypeAlias")) (ELit (LString "unexpanded type alias")))
(DFunDef false "reasonText" ((PCon "PEFunction")) (ELit (LString "function values have no built-in generator")))
(DFunDef false "reasonText" ((PCon "PEUnsupportedType")) (ELit (LString "unsupported parameter type")))
(DFunDef false "reasonText" ((PCon "PEOpaqueNominal")) (ELit (LString "opaque nominal type")))
(DFunDef false "reasonText" ((PCon "PEAmbiguousNominal")) (ELit (LString "ambiguous unresolved nominal type")))
(DFunDef false "reasonText" ((PCon "PENoFiniteValue")) (ELit (LString "recursive type has no finite constructor")))
(DFunDef false "reasonText" ((PCon "PEUnusableArbitrary")) (ELit (LString "Arbitrary instance cannot be selected for this carrier")))
(DFunDef false "reasonText" ((PCon "PEInaccessibleConstructors")) (ELit (LString "constructors are not visible to this property")))
(DData Public "ArbPlan" () ((variant "ArbPlan" (ConPos (TyCon "Ty") (TyCon "String")))) ())
(DData Public "PlanEnv" () ((variant "PlanEnv" (ConPos (TyCon "String") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "PlanDef"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "ArbPlan"))) (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))) ())
(DData Public "PlanModule" () ((variant "PlanModule" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DTypeSig false "emptyPlanEnv" (TyCon "PlanEnv"))
(DFunDef false "emptyPlanEnv" () (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (ELit (LString ""))) (EVar "omEmpty")) (EVar "omEmpty")) (EVar "omEmpty")) (EVar "omEmpty")))
(DTypeSig true "buildPlanEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "PlanEnv")))
(DFunDef false "buildPlanEnv" ((PVar "decls")) (EApp (EApp (EVar "buildPlanEnvGo") (EVar "decls")) (EVar "emptyPlanEnv")))
(DTypeSig true "buildPlanEnvModules" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))
(DFunDef false "buildPlanEnvModules" ((PVar "root") (PVar "modules")) (EApp (EApp (EVar "pairModules") (EVar "modules")) (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EVar "omEmpty")) (EVar "omEmpty")) (EVar "omEmpty")) (EVar "omEmpty"))))
(DTypeSig false "pairModules" (TyFun (TyApp (TyCon "List") (TyCon "PlanModule")) (TyFun (TyCon "PlanEnv") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))
(DFunDef false "pairModules" ((PList) (PVar "env")) (EApp (EVar "Ok") (EVar "env")))
(DFunDef false "pairModules" ((PCons (PCon "PlanModule" (PVar "mid") (PVar "raw") (PVar "runtime")) (PVar "rest")) (PVar "env")) (EMatch (EApp (EApp (EApp (EApp (EVar "pairModuleDecls") (EVar "mid")) (EVar "raw")) (EVar "runtime")) (EVar "env")) (arm (PCon "Ok" (PVar "env2")) () (EApp (EApp (EVar "pairModules") (EVar "rest")) (EVar "env2"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "pairModuleDecls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "PlanEnv") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))))
(DFunDef false "pairModuleDecls" ((PVar "mid") (PVar "raw") (PVar "runtime") (PVar "env")) (EIf (EApp (EApp (EVar "rawNominalsPresent") (EVar "raw")) (EVar "runtime")) (EApp (EApp (EApp (EApp (EVar "pairRuntimeDecls") (EVar "mid")) (EApp (EApp (EVar "rawNominalMap") (EVar "raw")) (EVar "omEmpty"))) (EVar "runtime")) (EVar "env")) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw nominal declaration has no runtime counterpart"))))))
(DTypeSig false "rawNominalsPresent" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "rawNominalsPresent" ((PList) PWild) (EVar "True"))
(DFunDef false "rawNominalsPresent" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "runtime")) (EApp (EApp (EVar "rawNominalsPresent") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "runtime")))
(DFunDef false "rawNominalsPresent" ((PCons (PRec "DData" ((rf "dataName" (PVar "name"))) false) (PVar "rest")) (PVar "runtime")) (EBinOp "&&" (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EVar "runtime")) (EApp (EApp (EVar "rawNominalsPresent") (EVar "rest")) (EVar "runtime"))))
(DFunDef false "rawNominalsPresent" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "name"))) false) (PVar "rest")) (PVar "runtime")) (EBinOp "&&" (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EVar "runtime")) (EApp (EApp (EVar "rawNominalsPresent") (EVar "rest")) (EVar "runtime"))))
(DFunDef false "rawNominalsPresent" ((PCons PWild (PVar "rest")) (PVar "runtime")) (EApp (EApp (EVar "rawNominalsPresent") (EVar "rest")) (EVar "runtime")))
(DTypeSig false "runtimeHasNominal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "runtimeHasNominal" (PWild (PList)) (EVar "False"))
(DFunDef false "runtimeHasNominal" ((PVar "name") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "runtimeHasNominal" ((PVar "name") (PCons (PRec "DData" ((rf "dataName" (PVar "actual"))) false) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "name") (EVar "actual")) (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EVar "rest"))))
(DFunDef false "runtimeHasNominal" ((PVar "name") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "actual"))) false) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "name") (EVar "actual")) (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EVar "rest"))))
(DFunDef false "runtimeHasNominal" ((PVar "name") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "runtimeHasNominal") (EVar "name")) (EVar "rest")))
(DTypeSig false "rawNominalMap" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "Decl")))))
(DFunDef false "rawNominalMap" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "rawNominalMap" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "rawNominalMap") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "rawNominalMap" ((PCons (PAs "d" (PRec "DData" ((rf "dataName" (PVar "name"))) false)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "rawNominalMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "d")) (EVar "acc"))))
(DFunDef false "rawNominalMap" ((PCons (PAs "d" (PRec "DNewtype" ((rf "newtypeName" (PVar "name"))) false)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "rawNominalMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "d")) (EVar "acc"))))
(DFunDef false "rawNominalMap" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "rawNominalMap") (EVar "rest")) (EVar "acc")))
(DTypeSig false "pairRuntimeDecls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "PlanEnv") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))))
(DFunDef false "pairRuntimeDecls" (PWild PWild (PList) (PVar "env")) (EApp (EVar "Ok") (EVar "env")))
(DFunDef false "pairRuntimeDecls" ((PVar "mid") (PVar "rawMap") (PCons (PVar "runtime") (PVar "rest")) (PVar "env")) (EMatch (EApp (EApp (EApp (EApp (EVar "pairRuntimeDecl") (EVar "mid")) (EVar "rawMap")) (EVar "runtime")) (EVar "env")) (arm (PCon "Ok" (PVar "env2")) () (EApp (EApp (EApp (EApp (EVar "pairRuntimeDecls") (EVar "mid")) (EVar "rawMap")) (EVar "rest")) (EVar "env2"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "pairRuntimeDecl" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Decl")) (TyFun (TyCon "Decl") (TyFun (TyCon "PlanEnv") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))))
(DFunDef false "pairRuntimeDecl" ((PVar "mid") (PVar "rawMap") (PCon "DAttrib" PWild (PVar "d")) (PVar "env")) (EApp (EApp (EApp (EApp (EVar "pairRuntimeDecl") (EVar "mid")) (EVar "rawMap")) (EVar "d")) (EVar "env")))
(DFunDef false "pairRuntimeDecl" ((PVar "mid") (PVar "rawMap") (PAs "runtime" (PRec "DData" ((rf "dataName" (PVar "name"))) false)) (PVar "env")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rawMap")) (arm (PCon "Some" (PVar "raw")) () (EApp (EApp (EApp (EApp (EVar "pairPlanDecl") (EVar "mid")) (EVar "raw")) (EVar "runtime")) (EVar "env"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "pairError") (EBinOp "++" (EBinOp "++" (ELit (LString "runtime data '")) (EVar "name")) (ELit (LString "' has no raw declaration"))))))))
(DFunDef false "pairRuntimeDecl" ((PVar "mid") (PVar "rawMap") (PAs "runtime" (PRec "DNewtype" ((rf "newtypeName" (PVar "name"))) false)) (PVar "env")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rawMap")) (arm (PCon "Some" (PVar "raw")) () (EApp (EApp (EApp (EApp (EVar "pairPlanDecl") (EVar "mid")) (EVar "raw")) (EVar "runtime")) (EVar "env"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "pairError") (EBinOp "++" (EBinOp "++" (ELit (LString "runtime newtype '")) (EVar "name")) (ELit (LString "' has no raw declaration"))))))))
(DFunDef false "pairRuntimeDecl" (PWild PWild (PVar "runtime") (PVar "env")) (EApp (EVar "Ok") (EApp (EApp (EVar "addPlanDeclRuntimeOnly") (EVar "runtime")) (EVar "env"))))
(DTypeSig false "addPlanDeclRuntimeOnly" (TyFun (TyCon "Decl") (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "addPlanDeclRuntimeOnly" ((PVar "runtime") (PVar "env")) (EApp (EApp (EVar "addPlanDecl") (EVar "runtime")) (EVar "env")))
(DTypeSig false "pairError" (TyFun (TyCon "String") (TyCon "PlanError")))
(DFunDef false "pairError" ((PVar "detail")) (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (ELit (LString ""))) (ELit (LString ""))) (EApp (EVar "TyVar") (ELit (LString "")))) (EVar "PEUnsupportedType")) (EVar "detail")))
(DTypeSig false "pairPlanDecl" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyFun (TyCon "Decl") (TyFun (TyCon "PlanEnv") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanEnv")))))))
(DFunDef false "pairPlanDecl" ((PVar "mid") (PCon "DAttrib" PWild (PVar "raw")) (PCon "DAttrib" PWild (PVar "runtime")) (PVar "env")) (EApp (EApp (EApp (EApp (EVar "pairPlanDecl") (EVar "mid")) (EVar "raw")) (EVar "runtime")) (EVar "env")))
(DFunDef false "pairPlanDecl" ((PVar "mid") (PRec "DData" ((rf "dataName" (PVar "rawName")) (rf "dataCtors" (PVar "rawCtors"))) false) (PRec "DData" ((rf "dataName" (PVar "runtimeName")) (rf "dataParams" (PVar "ps")) (rf "dataCtors" (PVar "runtimeCtors")) (rf "dataVis" (PVar "vis")) (rf "dataOrigin" (PVar "o"))) false) (PVar "env")) (EIf (EBinOp "==" (EVar "rawName") (EVar "runtimeName")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "TypeKey") (EVar "runtimeName")) (EVar "o"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "ctors")) (EApp (EApp (EVar "insertDef") (EApp (EApp (EApp (EApp (EApp (EVar "PlanDef") (EVar "key")) (EApp (EVar "ownerOf") (EVar "o"))) (EVar "ps")) (EApp (EVar "visibilityOf") (EVar "vis"))) (EVar "ctors"))) (EVar "env")))) (EApp (EApp (EVar "pairCtors") (EVar "rawCtors")) (EVar "runtimeCtors"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "pairPlanDecl" ((PVar "mid") (PRec "DNewtype" ((rf "newtypeName" (PVar "rawName")) (rf "newtypeCtor" (PVar "rawCtor"))) false) (PRec "DNewtype" ((rf "newtypeName" (PVar "runtimeName")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeCtor" (PVar "runtimeCtor")) (rf "newtypeFieldTy" (PVar "fieldTy")) (rf "newtypePub" (PVar "pub")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "env")) (EIf (EBinOp "==" (EVar "rawName") (EVar "runtimeName")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "TypeKey") (EVar "runtimeName")) (EVar "o"))) (DoLet false false (PVar "def") (EApp (EApp (EApp (EApp (EApp (EVar "PlanDef") (EVar "key")) (EApp (EVar "ownerOf") (EVar "o"))) (EVar "ps")) (EApp (EVar "newtypeVisibility") (EVar "pub"))) (EListLit (EApp (EApp (EApp (EVar "PlanCtor") (EVar "rawCtor")) (EVar "runtimeCtor")) (EListLit (EApp (EApp (EVar "PlanField") (EVar "None")) (EVar "fieldTy"))))))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EVar "insertDef") (EVar "def")) (EVar "env"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "pairPlanDecl" (PWild PWild PWild PWild) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw and runtime nominal declarations disagree")))))
(DTypeSig false "pairCtors" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "PlanCtor"))))))
(DFunDef false "pairCtors" ((PList) (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "pairCtors" ((PList) PWild) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime constructor counts disagree")))))
(DFunDef false "pairCtors" (PWild (PList)) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime constructor counts disagree")))))
(DFunDef false "pairCtors" ((PCons (PCon "Variant" (PVar "rawName") (PVar "rawPayload")) (PVar "raws")) (PCons (PCon "Variant" (PVar "runtimeName") (PVar "runtimePayload")) (PVar "runtimes"))) (EMatch (ETuple (EApp (EApp (EVar "pairFields") (EVar "rawPayload")) (EVar "runtimePayload")) (EApp (EApp (EVar "pairCtors") (EVar "raws")) (EVar "runtimes"))) (arm (PTuple (PCon "Ok" (PVar "fields")) (PCon "Ok" (PVar "rest"))) () (EApp (EVar "Ok") (EBinOp "::" (EApp (EApp (EApp (EVar "PlanCtor") (EVar "rawName")) (EVar "runtimeName")) (EVar "fields")) (EVar "rest")))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "pairFields" (TyFun (TyCon "ConPayload") (TyFun (TyCon "ConPayload") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "PlanField"))))))
(DFunDef false "pairFields" ((PCon "ConPos" (PVar "rawTys")) (PCon "ConPos" (PVar "runtimeTys"))) (EIf (EBinOp "==" (EApp (EVar "listLength") (EVar "rawTys")) (EApp (EVar "listLength") (EVar "runtimeTys"))) (EApp (EVar "Ok") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "PlanField") (EVar "None")) (EVar "t")))) (EVar "runtimeTys"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "pairFields" ((PCon "ConNamed" (PVar "rawFields") PWild) (PCon "ConNamed" (PVar "runtimeFields") PWild)) (EApp (EApp (EVar "pairNamedFields") (EVar "rawFields")) (EVar "runtimeFields")))
(DFunDef false "pairFields" (PWild PWild) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime constructor payloads disagree")))))
(DTypeSig false "pairNamedFields" (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "PlanField"))))))
(DFunDef false "pairNamedFields" ((PList) (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "pairNamedFields" ((PList) PWild) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime named field counts disagree")))))
(DFunDef false "pairNamedFields" (PWild (PList)) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime named field counts disagree")))))
(DFunDef false "pairNamedFields" ((PCons (PCon "Field" (PVar "rawName") PWild) (PVar "raws")) (PCons (PCon "Field" (PVar "runtimeName") (PVar "runtimeTy")) (PVar "runtimes"))) (EIf (EBinOp "==" (EVar "rawName") (EVar "runtimeName")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EApp (EApp (EVar "PlanField") (EApp (EVar "Some") (EVar "rawName"))) (EVar "runtimeTy")) (EVar "_s")))) (EApp (EApp (EVar "pairNamedFields") (EVar "raws")) (EVar "runtimes"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "pairNamedFields" (PWild PWild) (EApp (EVar "Err") (EApp (EVar "pairError") (ELit (LString "raw/runtime named field names disagree")))))
(DTypeSig false "listLength" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "listLength" ((PList)) (ELit (LInt 0)))
(DFunDef false "listLength" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "listLength") (EVar "xs"))))
(DTypeSig false "buildPlanEnvGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "buildPlanEnvGo" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "buildPlanEnvGo" ((PCons (PVar "d") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "buildPlanEnvGo") (EVar "rest")) (EApp (EApp (EVar "addPlanDecl") (EVar "d")) (EVar "env"))))
(DTypeSig false "addPlanDecl" (TyFun (TyCon "Decl") (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "addPlanDecl" ((PCon "DAttrib" PWild (PVar "d")) (PVar "env")) (EApp (EApp (EVar "addPlanDecl") (EVar "d")) (EVar "env")))
(DFunDef false "addPlanDecl" ((PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataCtors" (PVar "cs")) (rf "dataVis" (PVar "vis")) (rf "dataOrigin" (PVar "o"))) false) (PVar "env")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "TypeKey") (EVar "n")) (EVar "o"))) (DoLet false false (PVar "def") (EApp (EApp (EApp (EApp (EApp (EVar "PlanDef") (EVar "key")) (EApp (EVar "ownerOf") (EVar "o"))) (EVar "ps")) (EApp (EVar "visibilityOf") (EVar "vis"))) (EApp (EApp (EMethodRef "map") (EVar "ctorOfVariant")) (EVar "cs")))) (DoExpr (EApp (EApp (EVar "insertDef") (EVar "def")) (EVar "env")))))
(DFunDef false "addPlanDecl" ((PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeCtor" (PVar "c")) (rf "newtypeFieldTy" (PVar "t")) (rf "newtypePub" (PVar "pub")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "env")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "TypeKey") (EVar "n")) (EVar "o"))) (DoLet false false (PVar "def") (EApp (EApp (EApp (EApp (EApp (EVar "PlanDef") (EVar "key")) (EApp (EVar "ownerOf") (EVar "o"))) (EVar "ps")) (EApp (EVar "newtypeVisibility") (EVar "pub"))) (EListLit (EApp (EApp (EApp (EVar "PlanCtor") (EVar "c")) (EVar "c")) (EListLit (EApp (EApp (EVar "PlanField") (EVar "None")) (EVar "t"))))))) (DoExpr (EApp (EApp (EVar "insertDef") (EVar "def")) (EVar "env")))))
(DFunDef false "addPlanDecl" ((PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasOrigin" (PVar "o"))) false) (PCon "PlanEnv" (PVar "root") (PVar "defs") (PVar "arbs") (PVar "bad") (PVar "aliases"))) (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EVar "defs")) (EVar "arbs")) (EVar "bad")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n"))) (ELit LUnit)) (EVar "aliases"))))
(DFunDef false "addPlanDecl" ((PVar "d") (PVar "env")) (EApp (EApp (EVar "addArbitrary") (EVar "d")) (EVar "env")))
(DTypeSig false "visibilityOf" (TyFun (TyCon "DataVis") (TyCon "PlanVisibility")))
(DFunDef false "visibilityOf" ((PCon "VisPrivate")) (EVar "PlanLocal"))
(DFunDef false "visibilityOf" ((PCon "VisPublic")) (EVar "PlanPublicCtors"))
(DFunDef false "visibilityOf" ((PCon "VisAbstract")) (EVar "PlanAbstract"))
(DTypeSig false "newtypeVisibility" (TyFun (TyCon "Bool") (TyCon "PlanVisibility")))
(DFunDef false "newtypeVisibility" (PWild) (EVar "PlanLocal"))
(DTypeSig false "ownerOf" (TyFun (TyCon "TyConOrigin") (TyCon "String")))
(DFunDef false "ownerOf" ((PCon "OriginModule" (PVar "m"))) (EVar "m"))
(DFunDef false "ownerOf" (PWild) (ELit (LString "")))
(DTypeSig false "ctorOfVariant" (TyFun (TyCon "Variant") (TyCon "PlanCtor")))
(DFunDef false "ctorOfVariant" ((PCon "Variant" (PVar "c") (PCon "ConPos" (PVar "ts")))) (EApp (EApp (EApp (EVar "PlanCtor") (EVar "c")) (EVar "c")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "PlanField") (EVar "None")) (EVar "t")))) (EVar "ts"))))
(DFunDef false "ctorOfVariant" ((PCon "Variant" (PVar "c") (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EApp (EVar "PlanCtor") (EVar "c")) (EVar "c")) (EApp (EApp (EMethodRef "map") (EVar "namedField")) (EVar "fs"))))
(DTypeSig false "namedField" (TyFun (TyCon "Field") (TyCon "PlanField")))
(DFunDef false "namedField" ((PCon "Field" (PVar "n") (PVar "t"))) (EApp (EApp (EVar "PlanField") (EApp (EVar "Some") (EVar "n"))) (EVar "t")))
(DTypeSig false "addArbitrary" (TyFun (TyCon "Decl") (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "addArbitrary" ((PCon "DAttrib" PWild (PVar "d")) (PVar "env")) (EApp (EApp (EVar "addArbitrary") (EVar "d")) (EVar "env")))
(DFunDef false "addArbitrary" ((PRec "DImpl" ((rf "iface" (PLit (LString "Arbitrary"))) (rf "implOrigin" (PCon "OriginModule" (PLit (LString "core")))) (rf "tys" (PList (PVar "carrier")))) false) (PVar "env")) (EApp (EApp (EVar "insertArb") (EApp (EApp (EVar "ArbPlan") (EVar "carrier")) (EApp (EVar "arbCarrierWord") (EVar "carrier")))) (EVar "env")))
(DFunDef false "addArbitrary" (PWild (PVar "env")) (EVar "env"))
(DTypeSig false "arbCarrierWord" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "arbCarrierWord" ((PVar "ty")) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EApp (EVar "OriginModule") (ELit (LString "core")))) (ELit (LString "Arbitrary"))) (EListLit (EVar "ty"))) (EVar "None")))
(DTypeSig false "insertDef" (TyFun (TyCon "PlanDef") (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "insertDef" ((PAs "def" (PCon "PlanDef" (PVar "key") PWild PWild PWild PWild)) (PCon "PlanEnv" (PVar "root") (PVar "defs") (PVar "arbs") (PVar "bad") (PVar "aliases"))) (EBlock (DoLet false false (PVar "word") (EApp (EVar "typeKeyWord") (EVar "key"))) (DoLet false false (PVar "prior") (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "defs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EBinOp "::" (EVar "def") (EVar "prior"))) (EVar "defs"))) (EVar "arbs")) (EVar "bad")) (EVar "aliases")))))
(DTypeSig false "insertArb" (TyFun (TyCon "ArbPlan") (TyFun (TyCon "PlanEnv") (TyCon "PlanEnv"))))
(DFunDef false "insertArb" ((PAs "arb" (PCon "ArbPlan" (PVar "carrier") PWild)) (PCon "PlanEnv" (PVar "root") (PVar "defs") (PVar "arbs") (PVar "bad") (PVar "aliases"))) (EMatch (EApp (EVar "headKey") (EVar "carrier")) (arm (PCon "Some" (PVar "key")) () (EBlock (DoLet false false (PVar "word") (EApp (EVar "typeKeyWord") (EVar "key"))) (DoLet false false (PVar "prior") (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "arbs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EVar "defs")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EBinOp "::" (EVar "arb") (EVar "prior"))) (EVar "arbs"))) (EVar "bad")) (EVar "aliases"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EVar "defs")) (EVar "arbs")) (EVar "bad")) (EVar "aliases")))))
(DTypeSig false "optionList" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "optionList" ((PCon "None")) (EListLit))
(DFunDef false "optionList" ((PCon "Some" (PVar "xs"))) (EVar "xs"))
(DTypeSig false "planForGo" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "GenPlan")))))))
(DFunDef false "planForGo" (PWild (PVar "propName") (PVar "param") (PAs "ty" (PCon "TyVar" PWild))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "ty")) (EVar "PEUnboundTyVar")) (ELit (LString "")))))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "Int"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GInt")))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "Bool"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GBool")))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "Float"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GFloat")))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "Char"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GChar")))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "String"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GString")))
(DFunDef false "planForGo" (PWild PWild PWild (PRec "TyCon" ((rf "tyConName" (PLit (LString "Unit"))) (rf "tyConOrigin" (PCon "OriginBuiltin"))) false)) (EApp (EVar "Ok") (EVar "GUnit")))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "List"))) (rf "tyConOrigin" (PVar "o"))) false) (PVar "t"))) (EIf (EApp (EVar "builtinOrigin") (EVar "o")) (EApp (EApp (EMethodRef "map") (EVar "GList")) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Array"))) (rf "tyConOrigin" (PVar "o"))) false) (PVar "t"))) (EIf (EApp (EVar "builtinOrigin") (EVar "o")) (EApp (EApp (EMethodRef "map") (EVar "GArray")) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Option"))) (rf "tyConOrigin" (PVar "o"))) false) (PVar "t"))) (EIf (EApp (EVar "builtinOrigin") (EVar "o")) (EApp (EApp (EMethodRef "map") (EVar "GOption")) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyApp" (PCon "TyApp" (PRec "TyCon" ((rf "tyConName" (PLit (LString "Result"))) (rf "tyConOrigin" (PVar "o"))) false) (PVar "e")) (PVar "a"))) (EIf (EApp (EVar "builtinOrigin") (EVar "o")) (EApp (EApp (EApp (EDictApp "map2") (EVar "GResult")) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "a"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PVar "ty")) (EIf (EApp (EVar "builtinTupleSpine") (EVar "ty")) (EApp (EApp (EMethodRef "map") (EVar "GTuple")) (EApp (EApp (EApp (EApp (EVar "planMany") (EVar "env")) (EVar "propName")) (EVar "param")) (EApp (EVar "planArgs") (EVar "ty")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EMethodRef "map") (EVar "GTuple")) (EApp (EApp (EApp (EApp (EVar "planMany") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "ts"))))
(DFunDef false "planForGo" (PWild (PVar "propName") (PVar "param") (PAs "ty" (PCon "TyFun" PWild PWild))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "ty")) (EVar "PEFunction")) (ELit (LString "")))))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t")))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t")))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t")))
(DFunDef false "planForGo" ((PVar "env") (PVar "propName") (PVar "param") (PVar "ty")) (EMatch (EApp (EVar "headKey") (EVar "ty")) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "ty")) (EVar "PEUnsupportedType")) (ELit (LString ""))))) (arm (PCon "Some" (PVar "key")) () (EApp (EApp (EApp (EApp (EApp (EVar "planNominal") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "key")) (EApp (EVar "planArgs") (EVar "ty"))))))
(DTypeSig false "builtinOrigin" (TyFun (TyCon "TyConOrigin") (TyCon "Bool")))
(DFunDef false "builtinOrigin" ((PCon "OriginBuiltin")) (EVar "True"))
(DFunDef false "builtinOrigin" ((PCon "OriginModule" (PLit (LString "core")))) (EVar "True"))
(DFunDef false "builtinOrigin" (PWild) (EVar "False"))
(DTypeSig false "builtinTupleSpine" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "builtinTupleSpine" ((PVar "ty")) (EMatch (EApp (EVar "headKey") (EVar "ty")) (arm (PCon "Some" (PCon "TypeKey" (PLit (LString "__tuple2__")) (PCon "OriginBuiltin"))) () (EBinOp "==" (EApp (EVar "listLength") (EApp (EVar "planArgs") (EVar "ty"))) (ELit (LInt 2)))) (arm (PCon "Some" (PCon "TypeKey" (PLit (LString "__tuple3__")) (PCon "OriginBuiltin"))) () (EBinOp "==" (EApp (EVar "listLength") (EApp (EVar "planArgs") (EVar "ty"))) (ELit (LInt 3)))) (arm (PCon "Some" (PCon "TypeKey" (PLit (LString "__tuple4__")) (PCon "OriginBuiltin"))) () (EBinOp "==" (EApp (EVar "listLength") (EApp (EVar "planArgs") (EVar "ty"))) (ELit (LInt 4)))) (arm (PCon "Some" (PCon "TypeKey" (PLit (LString "__tuple5__")) (PCon "OriginBuiltin"))) () (EBinOp "==" (EApp (EVar "listLength") (EApp (EVar "planArgs") (EVar "ty"))) (ELit (LInt 5)))) (arm PWild () (EVar "False"))))
(DTypeSig false "headKey" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "TypeKey"))))
(DFunDef false "headKey" ((PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false)) (EApp (EVar "Some") (EApp (EApp (EVar "TypeKey") (EVar "n")) (EVar "o"))))
(DFunDef false "headKey" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "headKey") (EVar "f")))
(DFunDef false "headKey" (PWild) (EVar "None"))
(DTypeSig false "planArgs" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "planArgs" ((PVar "t")) (EApp (EApp (EVar "planArgsGo") (EListLit)) (EVar "t")))
(DTypeSig false "planArgsGo" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "planArgsGo" ((PVar "acc") (PCon "TyApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "planArgsGo") (EBinOp "::" (EVar "a") (EVar "acc"))) (EVar "f")))
(DFunDef false "planArgsGo" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "planNominal" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "GenPlan"))))))))
(DFunDef false "planNominal" ((PCon "PlanEnv" (PVar "root") (PVar "defs") (PVar "arbs") (PVar "bad") (PVar "aliases")) (PVar "propName") (PVar "param") (PVar "key") (PVar "args")) (EBlock (DoLet false false (PVar "carrier") (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "selectedCustom") (EVar "key")) (EVar "carrier")) (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EApp (EVar "typeKeyWord") (EVar "key"))) (EVar "arbs")))) (arm (PCon "Err" (PVar "detail")) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "carrier")) (EVar "PEUnusableArbitrary")) (EVar "detail")))) (arm (PCon "Ok" (PCon "Some" (PVar "custom"))) () (EApp (EVar "Ok") (EApp (EVar "GCustom") (EVar "custom")))) (arm (PCon "Ok" (PCon "None")) () (EMatch (EApp (EApp (EVar "matchingDef") (EVar "key")) (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EApp (EVar "typeKeyWord") (EVar "key"))) (EVar "defs")))) (arm (PCon "None") ((GBool (EApp (EVar "isSome") (EApp (EApp (EVar "omLookup") (EApp (EVar "typeKeyWord") (EVar "key"))) (EVar "aliases"))))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PETypeAlias")) (ELit (LString ""))))) (arm (PCon "None") ((GBool (EApp (EApp (EVar "hasAmbiguousUnresolved") (EVar "key")) (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EApp (EVar "typeKeyWord") (EVar "key"))) (EVar "defs")))))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PEAmbiguousNominal")) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PEOpaqueNominal")) (ELit (LString "no visible data declaration"))))) (arm (PCon "Some" (PCon "PlanDef" PWild (PVar "owner") PWild (PCon "PlanAbstract") PWild)) ((GBool (EBinOp "/=" (EVar "owner") (EVar "root")))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PEOpaqueNominal")) (ELit (LString ""))))) (arm (PCon "Some" (PCon "PlanDef" PWild (PVar "owner") PWild (PCon "PlanLocal") PWild)) ((GBool (EBinOp "/=" (EVar "owner") (EVar "root")))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PEInaccessibleConstructors")) (ELit (LString ""))))) (arm (PCon "Some" (PCon "PlanDef" PWild PWild PWild PWild (PList))) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EVar "args"))) (EVar "PENoFiniteValue")) (ELit (LString "no constructors"))))) (arm (PCon "Some" (PCon "PlanDef" PWild PWild PWild PWild PWild)) () (EApp (EApp (EMethodRef "map") (EApp (EVar "GNominal") (EVar "key"))) (EApp (EApp (EApp (EApp (EVar "planMany") (EApp (EApp (EApp (EApp (EApp (EVar "PlanEnv") (EVar "root")) (EVar "defs")) (EVar "arbs")) (EVar "bad")) (EVar "aliases"))) (EVar "propName")) (EVar "param")) (EVar "args"))))))))))
(DTypeSig false "selectedCustom" (TyFun (TyCon "TypeKey") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "ArbPlan")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "CustomPlan")))))))
(DFunDef false "selectedCustom" ((PVar "key") (PVar "carrier") (PVar "candidates")) (EMatch (EApp (EApp (EVar "exactArbs") (EVar "carrier")) (EVar "candidates")) (arm (PList) () (EMatch (EApp (EApp (EVar "matchingArbs") (EVar "carrier")) (EVar "candidates")) (arm (PList) () (EApp (EVar "Ok") (EVar "None"))) (arm PWild () (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "CustomPlan") (EVar "key")) (EVar "carrier")) (EApp (EVar "arbCarrierWord") (EVar "carrier")))))))) (arm (PList PWild) () (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "CustomPlan") (EVar "key")) (EVar "carrier")) (EApp (EVar "arbCarrierWord") (EVar "carrier")))))) (arm PWild () (EApp (EVar "Err") (ELit (LString "multiple exact Arbitrary instances select this carrier"))))))
(DTypeSig false "exactArbs" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "ArbPlan")) (TyApp (TyCon "List") (TyCon "ArbPlan")))))
(DFunDef false "exactArbs" (PWild (PList)) (EListLit))
(DFunDef false "exactArbs" ((PVar "carrier") (PCons (PAs "arb" (PCon "ArbPlan" (PVar "pattern") PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "arbCarrierWord") (EVar "pattern")) (EApp (EVar "arbCarrierWord") (EVar "carrier"))) (EBinOp "::" (EVar "arb") (EApp (EApp (EVar "exactArbs") (EVar "carrier")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "exactArbs") (EVar "carrier")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchingArbs" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "ArbPlan")) (TyApp (TyCon "List") (TyCon "ArbPlan")))))
(DFunDef false "matchingArbs" (PWild (PList)) (EListLit))
(DFunDef false "matchingArbs" ((PVar "carrier") (PCons (PAs "arb" (PCon "ArbPlan" (PVar "pattern") PWild)) (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "matchArbCarrier") (EVar "pattern")) (EVar "carrier")) (EVar "omEmpty")) (arm (PCon "Some" PWild) () (EBinOp "::" (EVar "arb") (EApp (EApp (EVar "matchingArbs") (EVar "carrier")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "matchingArbs") (EVar "carrier")) (EVar "rest")))))
(DTypeSig false "matchArbCarrier" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "OrdMap") (TyCon "Ty")))))))
(DFunDef false "matchArbCarrier" ((PCon "TyVar" (PVar "name")) (PVar "actual") (PVar "bindings")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "bindings")) (arm (PCon "Some" (PVar "bound")) () (EIf (EBinOp "==" (EApp (EVar "arbCarrierWord") (EVar "bound")) (EApp (EVar "arbCarrierWord") (EVar "actual"))) (EApp (EVar "Some") (EVar "bindings")) (EVar "None"))) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "actual")) (EVar "bindings"))))))
(DFunDef false "matchArbCarrier" ((PCon "TyApp" (PVar "pf") (PVar "pa")) (PCon "TyApp" (PVar "af") (PVar "aa")) (PVar "bindings")) (EMatch (EApp (EApp (EApp (EVar "matchArbCarrier") (EVar "pf")) (EVar "af")) (EVar "bindings")) (arm (PCon "Some" (PVar "next")) () (EApp (EApp (EApp (EVar "matchArbCarrier") (EVar "pa")) (EVar "aa")) (EVar "next"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "matchArbCarrier" ((PCon "TyTuple" (PVar "ps")) (PCon "TyTuple" (PVar "actuals")) (PVar "bindings")) (EApp (EApp (EApp (EVar "matchArbCarriers") (EVar "ps")) (EVar "actuals")) (EVar "bindings")))
(DFunDef false "matchArbCarrier" ((PVar "pattern") (PVar "actual") (PVar "bindings")) (EIf (EBinOp "==" (EApp (EVar "arbCarrierWord") (EVar "pattern")) (EApp (EVar "arbCarrierWord") (EVar "actual"))) (EApp (EVar "Some") (EVar "bindings")) (EVar "None")))
(DTypeSig false "matchArbCarriers" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "OrdMap") (TyCon "Ty")))))))
(DFunDef false "matchArbCarriers" ((PList) (PList) (PVar "bindings")) (EApp (EVar "Some") (EVar "bindings")))
(DFunDef false "matchArbCarriers" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "restActuals")) (PVar "bindings")) (EMatch (EApp (EApp (EApp (EVar "matchArbCarrier") (EVar "p")) (EVar "a")) (EVar "bindings")) (arm (PCon "Some" (PVar "next")) () (EApp (EApp (EApp (EVar "matchArbCarriers") (EVar "ps")) (EVar "restActuals")) (EVar "next"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "matchArbCarriers" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "matchingDef" (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "PlanDef")) (TyApp (TyCon "Option") (TyCon "PlanDef")))))
(DFunDef false "matchingDef" (PWild (PList)) (EVar "None"))
(DFunDef false "matchingDef" ((PVar "key") (PCons (PAs "d" (PCon "PlanDef" (PVar "actual") PWild PWild PWild PWild)) (PVar "rest"))) (EIf (EApp (EApp (EVar "sameTypeKey") (EVar "key")) (EVar "actual")) (EApp (EVar "Some") (EVar "d")) (EApp (EApp (EVar "matchingDef") (EVar "key")) (EVar "rest"))))
(DTypeSig false "hasAmbiguousUnresolved" (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "PlanDef")) (TyCon "Bool"))))
(DFunDef false "hasAmbiguousUnresolved" ((PCon "TypeKey" (PVar "n") (PCon "OriginUnresolved")) (PVar "defs")) (EBinOp ">" (EApp (EVar "listLength") (EVar "defs")) (ELit (LInt 1))))
(DFunDef false "hasAmbiguousUnresolved" (PWild PWild) (EVar "False"))
(DTypeSig false "rebuildTy" (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "rebuildTy" ((PCon "TypeKey" (PVar "n") (PVar "o")) (PVar "args")) (EApp (EApp (EVar "foldTy") (ERecordCreate "TyCon" ((fa "tyConName" (EVar "n")) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "o"))))) (EVar "args")))
(DTypeSig false "foldTy" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "foldTy" ((PVar "t") (PList)) (EVar "t"))
(DFunDef false "foldTy" ((PVar "t") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "foldTy") (EApp (EApp (EVar "TyApp") (EVar "t")) (EVar "a"))) (EVar "rest")))
(DTypeSig false "planMany" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "GenPlan"))))))))
(DFunDef false "planMany" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "planMany" ((PVar "env") (PVar "propName") (PVar "param") (PCons (PVar "t") (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "planMany") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "p")) (PCon "Ok" (PVar "ps"))) () (EApp (EVar "Ok") (EBinOp "::" (EVar "p") (EVar "ps")))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "planDef" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "TypeKey") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanDef")))))
(DFunDef false "planDef" ((PCon "PlanEnv" PWild (PVar "defs") PWild PWild PWild) (PVar "key")) (EMatch (EApp (EApp (EVar "matchingDef") (EVar "key")) (EApp (EVar "optionList") (EApp (EApp (EVar "omLookup") (EApp (EVar "typeKeyWord") (EVar "key"))) (EVar "defs")))) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Ok") (EVar "d"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (ELit (LString ""))) (ELit (LString ""))) (EApp (EApp (EVar "rebuildTy") (EVar "key")) (EListLit))) (EVar "PEAmbiguousNominal")) (ELit (LString "")))))))
(DTypeSig true "instantiateCtor" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))))))))
(DFunDef false "instantiateCtor" ((PVar "env") (PCon "GNominal" (PVar "key") (PVar "args")) (PCon "PlanCtor" PWild PWild (PVar "fields"))) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild (PVar "params") PWild PWild)) () (EApp (EApp (EApp (EApp (EVar "instantiateFields") (EVar "env")) (EVar "params")) (EVar "args")) (EVar "fields"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DFunDef false "instantiateCtor" (PWild (PVar "p") PWild) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (ELit (LString ""))) (ELit (LString ""))) (EApp (EVar "TyVar") (ELit (LString "")))) (EVar "PEUnsupportedType")) (EBinOp "++" (ELit (LString "not nominal: ")) (EApp (EVar "planKind") (EVar "p"))))))
(DTypeSig true "customPlansReachable" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))
(DFunDef false "customPlansReachable" ((PVar "env") (PVar "plans")) (EApp (EVar "reverseCustomPlans") (EApp (EApp (EApp (EApp (EVar "customPlansGo") (EVar "env")) (EVar "plans")) (EVar "omEmpty")) (EListLit))))
(DTypeSig false "reverseCustomPlans" (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyApp (TyCon "List") (TyCon "CustomPlan"))))
(DFunDef false "reverseCustomPlans" ((PVar "plans")) (EApp (EApp (EVar "reverseCustomPlansGo") (EVar "plans")) (EListLit)))
(DTypeSig false "reverseCustomPlansGo" (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))
(DFunDef false "reverseCustomPlansGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseCustomPlansGo" ((PCons (PVar "plan") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "reverseCustomPlansGo") (EVar "rest")) (EBinOp "::" (EVar "plan") (EVar "acc"))))
(DTypeSig false "customPlansGo" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))))
(DFunDef false "customPlansGo" (PWild (PList) PWild (PVar "found")) (EVar "found"))
(DFunDef false "customPlansGo" ((PVar "env") (PCons (PVar "plan") (PVar "rest")) (PVar "seen") (PVar "found")) (EBlock (DoLet false false (PTuple (PVar "seen2") (PVar "found2")) (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (ELit (LInt 0))) (EVar "plan")) (EVar "seen")) (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "customPlansGo") (EVar "env")) (EVar "rest")) (EVar "seen2")) (EVar "found2")))))
(DTypeSig false "customPlansIn" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))))))
(DFunDef false "customPlansIn" ((PVar "env") (PVar "depth") (PVar "plan") (PVar "seen") (PVar "found")) (EBlock (DoLet false false (PVar "word") (EApp (EVar "arbCarrierWord") (EApp (EVar "planTy") (EVar "plan")))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "seen")) (ETuple (EVar "seen") (EVar "found")) (EBlock (DoLet false false (PVar "visited") (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EMatch (EVar "plan") (arm (PCon "GCustom" (PVar "custom")) () (ETuple (EVar "visited") (EBinOp "::" (EVar "custom") (EVar "found")))) (arm (PCon "GList" (PVar "item")) () (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "item")) (EVar "visited")) (EVar "found"))) (arm (PCon "GArray" (PVar "item")) () (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "item")) (EVar "visited")) (EVar "found"))) (arm (PCon "GOption" (PVar "item")) () (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "item")) (EVar "visited")) (EVar "found"))) (arm (PCon "GResult" (PVar "err") (PVar "ok")) () (EBlock (DoLet false false (PTuple (PVar "afterErr") (PVar "foundErr")) (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "err")) (EVar "visited")) (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "ok")) (EVar "afterErr")) (EVar "foundErr"))))) (arm (PCon "GTuple" (PVar "items")) () (EApp (EApp (EApp (EApp (EApp (EVar "customPlansState") (EVar "env")) (EVar "depth")) (EVar "items")) (EVar "visited")) (EVar "found"))) (arm (PAs "nominal" (PCon "GNominal" (PVar "key") PWild)) () (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "customPlansCtors") (EVar "env")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "nominal")) (EVar "ctors")) (EApp (EApp (EApp (EVar "ctorWeights") (EVar "env")) (EVar "nominal")) (EVar "depth"))) (EVar "visited")) (EVar "found"))) (arm (PCon "Err" PWild) () (ETuple (EVar "visited") (EVar "found"))))) (arm PWild () (ETuple (EVar "visited") (EVar "found"))))))))))
(DTypeSig false "customPlansState" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))))))
(DFunDef false "customPlansState" (PWild PWild (PList) (PVar "seen") (PVar "found")) (ETuple (EVar "seen") (EVar "found")))
(DFunDef false "customPlansState" ((PVar "env") (PVar "depth") (PCons (PVar "plan") (PVar "rest")) (PVar "seen") (PVar "found")) (EBlock (DoLet false false (PTuple (PVar "seen2") (PVar "found2")) (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "plan")) (EVar "seen")) (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "customPlansState") (EVar "env")) (EVar "depth")) (EVar "rest")) (EVar "seen2")) (EVar "found2")))))
(DTypeSig false "customPlansCtors" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))))))))
(DFunDef false "customPlansCtors" (PWild PWild PWild (PList) PWild (PVar "seen") (PVar "found")) (ETuple (EVar "seen") (EVar "found")))
(DFunDef false "customPlansCtors" (PWild PWild PWild PWild (PList) (PVar "seen") (PVar "found")) (ETuple (EVar "seen") (EVar "found")))
(DFunDef false "customPlansCtors" ((PVar "env") (PVar "depth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PCons (PVar "weight") (PVar "weights")) (PVar "seen") (PVar "found")) (EIf (EBinOp "<=" (EVar "weight") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "customPlansCtors") (EVar "env")) (EVar "depth")) (EVar "nominal")) (EVar "rest")) (EVar "weights")) (EVar "seen")) (EVar "found")) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EBlock (DoLet false false (PTuple (PVar "seen2") (PVar "found2")) (EApp (EApp (EApp (EApp (EApp (EVar "customPlansFields") (EVar "env")) (EVar "depth")) (EVar "fields")) (EVar "seen")) (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "customPlansCtors") (EVar "env")) (EVar "depth")) (EVar "nominal")) (EVar "rest")) (EVar "weights")) (EVar "seen2")) (EVar "found2"))))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "customPlansCtors") (EVar "env")) (EVar "depth")) (EVar "nominal")) (EVar "rest")) (EVar "weights")) (EVar "seen")) (EVar "found"))))))
(DTypeSig false "customPlansFields" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CustomPlan")) (TyTuple (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "CustomPlan")))))))))
(DFunDef false "customPlansFields" (PWild PWild (PList) (PVar "seen") (PVar "found")) (ETuple (EVar "seen") (EVar "found")))
(DFunDef false "customPlansFields" ((PVar "env") (PVar "depth") (PCons (PTuple PWild (PVar "plan")) (PVar "rest")) (PVar "seen") (PVar "found")) (EBlock (DoLet false false (PTuple (PVar "seen2") (PVar "found2")) (EApp (EApp (EApp (EApp (EApp (EVar "customPlansIn") (EVar "env")) (EVar "depth")) (EVar "plan")) (EVar "seen")) (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "customPlansFields") (EVar "env")) (EVar "depth")) (EVar "rest")) (EVar "seen2")) (EVar "found2")))))
(DTypeSig false "planKind" (TyFun (TyCon "GenPlan") (TyCon "String")))
(DFunDef false "planKind" ((PCon "GInt")) (ELit (LString "Int")))
(DFunDef false "planKind" ((PCon "GBool")) (ELit (LString "Bool")))
(DFunDef false "planKind" ((PCon "GFloat")) (ELit (LString "Float")))
(DFunDef false "planKind" ((PCon "GChar")) (ELit (LString "Char")))
(DFunDef false "planKind" ((PCon "GString")) (ELit (LString "String")))
(DFunDef false "planKind" ((PCon "GUnit")) (ELit (LString "Unit")))
(DFunDef false "planKind" (PWild) (ELit (LString "compound")))
(DTypeSig false "instantiateFields" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "List") (TyCon "PlanField")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan")))))))))
(DFunDef false "instantiateFields" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "instantiateFields" ((PVar "env") (PVar "params") (PVar "args") (PCons (PCon "PlanField" (PVar "name") (PVar "ty")) (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planTyWithPlans") (EVar "env")) (ELit (LString ""))) (EApp (EApp (EVar "zipL") (EVar "params")) (EVar "args"))) (EVar "ty")) (EApp (EApp (EApp (EApp (EVar "instantiateFields") (EVar "env")) (EVar "params")) (EVar "args")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "p")) (PCon "Ok" (PVar "ps"))) () (EApp (EVar "Ok") (EBinOp "::" (ETuple (EVar "name") (EVar "p")) (EVar "ps")))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "planTyWithPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "GenPlan"))) (TyFun (TyCon "Ty") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "GenPlan")))))))
(DFunDef false "planTyWithPlans" (PWild (PVar "param") (PVar "subst") (PCon "TyVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "subst")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "Ok") (EVar "p"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (ELit (LString ""))) (EVar "param")) (EApp (EVar "TyVar") (EVar "n"))) (EVar "PEUnboundTyVar")) (ELit (LString "")))))))
(DFunDef false "planTyWithPlans" ((PVar "env") (PVar "param") (PVar "subst") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (ELit (LString ""))) (EVar "param")) (EApp (EApp (EVar "substTy") (EVar "subst")) (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))))
(DFunDef false "planTyWithPlans" ((PVar "env") (PVar "param") (PVar "subst") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EMethodRef "map") (EVar "GTuple")) (EApp (EApp (EApp (EApp (EVar "planManySubst") (EVar "env")) (EVar "param")) (EVar "subst")) (EVar "ts"))))
(DFunDef false "planTyWithPlans" ((PVar "env") (PVar "param") (PVar "subst") (PVar "t")) (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (ELit (LString ""))) (EVar "param")) (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "t"))))
(DTypeSig false "planManySubst" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "GenPlan"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyApp (TyCon "List") (TyCon "GenPlan"))))))))
(DFunDef false "planManySubst" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "planManySubst" ((PVar "env") (PVar "param") (PVar "subst") (PCons (PVar "t") (PVar "rest"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "planTyWithPlans") (EVar "env")) (EVar "param")) (EVar "subst")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "planManySubst") (EVar "env")) (EVar "param")) (EVar "subst")) (EVar "rest"))) (arm (PTuple (PCon "Ok" (PVar "p")) (PCon "Ok" (PVar "ps"))) () (EApp (EVar "Ok") (EBinOp "::" (EVar "p") (EVar "ps")))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "substTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "GenPlan"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substTy" ((PVar "subst") (PVar "t")) (EApp (EApp (EVar "substTyRaw") (EApp (EApp (EMethodRef "map") (EVar "planSubstPair")) (EVar "subst"))) (EVar "t")))
(DTypeSig false "planSubstPair" (TyFun (TyTuple (TyCon "String") (TyCon "GenPlan")) (TyTuple (TyCon "String") (TyCon "Ty"))))
(DFunDef false "planSubstPair" ((PTuple (PVar "n") (PVar "p"))) (ETuple (EVar "n") (EApp (EVar "planTy") (EVar "p"))))
(DTypeSig true "substTyRaw" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EApp (EVar "TyVar") (EVar "n")))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "substTyRaw") (EVar "subst"))) (EVar "ts"))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EApp (EApp (EApp (EVar "TyEffect") (EVar "es")) (EVar "tail")) (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "t"))))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyNamed" (PVar "n") (PVar "t") (PVar "dom"))) (EApp (EApp (EApp (EVar "TyNamed") (EVar "n")) (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "t"))) (EVar "dom")))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyQual" (PVar "t") (PVar "qs") (PVar "loc"))) (EApp (EApp (EApp (EVar "TyQual") (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "t"))) (EVar "qs")) (EVar "loc")))
(DFunDef false "substTyRaw" ((PVar "subst") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EApp (EVar "substTyRaw") (EVar "subst")) (EVar "t"))))
(DFunDef false "substTyRaw" (PWild (PVar "t")) (EVar "t"))
(DTypeSig true "planTy" (TyFun (TyCon "GenPlan") (TyCon "Ty")))
(DFunDef false "planTy" ((PCon "GInt")) (EApp (EVar "builtinTy") (ELit (LString "Int"))))
(DFunDef false "planTy" ((PCon "GBool")) (EApp (EVar "builtinTy") (ELit (LString "Bool"))))
(DFunDef false "planTy" ((PCon "GFloat")) (EApp (EVar "builtinTy") (ELit (LString "Float"))))
(DFunDef false "planTy" ((PCon "GChar")) (EApp (EVar "builtinTy") (ELit (LString "Char"))))
(DFunDef false "planTy" ((PCon "GString")) (EApp (EVar "builtinTy") (ELit (LString "String"))))
(DFunDef false "planTy" ((PCon "GUnit")) (EApp (EVar "builtinTy") (ELit (LString "Unit"))))
(DFunDef false "planTy" ((PCon "GList" (PVar "p"))) (EApp (EApp (EVar "TyApp") (EApp (EVar "builtinTy") (ELit (LString "List")))) (EApp (EVar "planTy") (EVar "p"))))
(DFunDef false "planTy" ((PCon "GArray" (PVar "p"))) (EApp (EApp (EVar "TyApp") (EApp (EVar "builtinTy") (ELit (LString "Array")))) (EApp (EVar "planTy") (EVar "p"))))
(DFunDef false "planTy" ((PCon "GOption" (PVar "p"))) (EApp (EApp (EVar "TyApp") (EApp (EVar "builtinTy") (ELit (LString "Option")))) (EApp (EVar "planTy") (EVar "p"))))
(DFunDef false "planTy" ((PCon "GResult" (PVar "e") (PVar "a"))) (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "TyApp") (EApp (EVar "builtinTy") (ELit (LString "Result")))) (EApp (EVar "planTy") (EVar "e")))) (EApp (EVar "planTy") (EVar "a"))))
(DFunDef false "planTy" ((PCon "GTuple" (PVar "ps"))) (EApp (EVar "TyTuple") (EApp (EApp (EMethodRef "map") (EVar "planTy")) (EVar "ps"))))
(DFunDef false "planTy" ((PCon "GNominal" (PCon "TypeKey" (PVar "n") (PVar "o")) (PVar "ps"))) (EApp (EApp (EVar "foldTy") (ERecordCreate "TyCon" ((fa "tyConName" (EVar "n")) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "o"))))) (EApp (EApp (EMethodRef "map") (EVar "planTy")) (EVar "ps"))))
(DFunDef false "planTy" ((PCon "GCustom" (PCon "CustomPlan" PWild (PVar "carrier") PWild))) (EVar "carrier"))
(DTypeSig false "builtinTy" (TyFun (TyCon "String") (TyCon "Ty")))
(DFunDef false "builtinTy" ((PVar "n")) (ERecordCreate "TyCon" ((fa "tyConName" (EVar "n")) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginBuiltin")))))
(DTypeSig true "intMin" (TyCon "Int"))
(DFunDef false "intMin" () (EUnOp "-" (ELit (LInt 1000))))
(DTypeSig true "intMax" (TyCon "Int"))
(DFunDef false "intMax" () (ELit (LInt 1000)))
(DTypeSig true "charMin" (TyCon "Int"))
(DFunDef false "charMin" () (ELit (LInt 32)))
(DTypeSig true "charMax" (TyCon "Int"))
(DFunDef false "charMax" () (ELit (LInt 126)))
(DTypeSig true "stringMaxLength" (TyCon "Int"))
(DFunDef false "stringMaxLength" () (ELit (LInt 10)))
(DTypeSig true "listLenMax" (TyCon "Int"))
(DFunDef false "listLenMax" () (ELit (LInt 7)))
(DTypeSig true "recWeight0" (TyCon "Int"))
(DFunDef false "recWeight0" () (ELit (LInt 6)))
(DTypeSig true "maxGenDepth" (TyCon "Int"))
(DFunDef false "maxGenDepth" () (ELit (LInt 24)))
(DTypeSig true "ctorWeights" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "ctorWeights" ((PVar "env") (PAs "nominal" (PCon "GNominal" PWild PWild)) (PVar "depth")) (EMatch (EApp (EApp (EVar "nominalCtors") (EVar "env")) (EVar "nominal")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EIf (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "boundCtorWeight") (EVar "env")) (EVar "nominal"))) (EVar "ctors")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "softCtorWeight") (EVar "env")) (EVar "nominal")) (EVar "depth"))) (EVar "ctors")))) (arm (PCon "Err" PWild) () (EListLit))))
(DFunDef false "ctorWeights" (PWild PWild PWild) (EListLit))
(DTypeSig false "nominalCtors" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "PlanDef")))))
(DFunDef false "nominalCtors" ((PVar "env") (PCon "GNominal" (PVar "key") PWild)) (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")))
(DFunDef false "nominalCtors" (PWild (PVar "plan")) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (ELit (LString ""))) (ELit (LString ""))) (EApp (EVar "planTy") (EVar "plan"))) (EVar "PEUnsupportedType")) (ELit (LString "not a nominal plan")))))
(DData Public "SoftWeight" () ((variant "SoftNever" (ConPos)) (variant "SoftFixed" (ConPos (TyCon "Int"))) (variant "SoftDecaying" (ConPos (TyCon "Int")))) ())
(DTypeSig true "softCtorWeights" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyApp (TyCon "List") (TyCon "SoftWeight")))))
(DFunDef false "softCtorWeights" ((PVar "env") (PAs "nominal" (PCon "GNominal" PWild PWild))) (EMatch (EApp (EApp (EVar "nominalCtors") (EVar "env")) (EVar "nominal")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "softCtorWeightForm") (EVar "env")) (EVar "nominal"))) (EVar "ctors"))) (arm (PCon "Err" PWild) () (EListLit))))
(DFunDef false "softCtorWeights" (PWild PWild) (EListLit))
(DTypeSig false "softWeightAt" (TyFun (TyCon "Int") (TyFun (TyCon "SoftWeight") (TyCon "Int"))))
(DFunDef false "softWeightAt" (PWild (PCon "SoftNever")) (ELit (LInt 0)))
(DFunDef false "softWeightAt" (PWild (PCon "SoftFixed" (PVar "weight"))) (EVar "weight"))
(DFunDef false "softWeightAt" ((PVar "depth") (PCon "SoftDecaying" (PVar "start"))) (EApp (EApp (EMethodRef "max") (ELit (LInt 1))) (EBinOp "-" (EVar "start") (EVar "depth"))))
(DTypeSig false "softCtorWeightForm" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyCon "SoftWeight")))))
(DFunDef false "softCtorWeightForm" ((PVar "env") (PVar "nominal") (PVar "ctor")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "ctorHasFiniteFields") (EVar "env")) (EVar "nominal")) (EVar "ctor"))) (EVar "SoftNever") (EIf (EApp (EApp (EApp (EVar "ctorCanDiverge") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (EApp (EVar "SoftDecaying") (EVar "recWeight0")) (EApp (EVar "SoftFixed") (EVar "recWeight0")))))
(DTypeSig false "softCtorWeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyFun (TyCon "PlanCtor") (TyCon "Int"))))))
(DFunDef false "softCtorWeight" ((PVar "env") (PVar "nominal") (PVar "depth") (PVar "ctor")) (EApp (EApp (EVar "softWeightAt") (EVar "depth")) (EApp (EApp (EApp (EVar "softCtorWeightForm") (EVar "env")) (EVar "nominal")) (EVar "ctor"))))
(DTypeSig false "ctorHasFiniteFields" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyCon "Bool")))))
(DFunDef false "ctorHasFiniteFields" ((PVar "env") (PVar "nominal") (PVar "ctor")) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EVar "allPlansFinite") (EVar "env")) (EApp (EVar "fieldPlansOnly") (EVar "fields")))) (arm (PCon "Err" PWild) () (EVar "False"))))
(DTypeSig false "ctorCanDiverge" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyCon "Bool")))))
(DFunDef false "ctorCanDiverge" ((PVar "env") (PVar "nominal") (PVar "ctor")) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EVar "anyPlanDiverges") (EVar "env")) (EApp (EVar "fieldPlansOnly") (EVar "fields")))) (arm (PCon "Err" PWild) () (EVar "False"))))
(DTypeSig false "boundCtorWeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyCon "Int")))))
(DFunDef false "boundCtorWeight" ((PVar "env") (PVar "nominal") (PVar "ctor")) (EIf (EApp (EApp (EApp (EVar "ctorLowersFiniteHeight") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (ELit (LInt 1)) (ELit (LInt 0))))
(DTypeSig false "ctorLowersFiniteHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyCon "Bool")))))
(DFunDef false "ctorLowersFiniteHeight" ((PVar "env") (PVar "nominal") (PVar "ctor")) (EMatch (ETuple (EApp (EApp (EApp (EVar "planFiniteHeight") (EVar "env")) (EVar "nominal")) (EListLit)) (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor"))) (arm (PTuple (PCon "Some" (PVar "height")) (PCon "Ok" (PVar "fields"))) () (EApp (EApp (EApp (EVar "allPlansBelow") (EVar "env")) (EVar "height")) (EApp (EVar "fieldPlansOnly") (EVar "fields")))) (arm PWild () (EVar "False"))))
(DTypeSig false "planHasFiniteValue" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Bool"))))
(DFunDef false "planHasFiniteValue" ((PVar "env") (PVar "plan")) (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "plan"))) (EVar "plan")))
(DTypeSig false "planFiniteHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "TypeKey")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "planFiniteHeight" ((PVar "env") (PVar "plan") PWild) (EBlock (DoLet false false (PVar "truth") (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "plan"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EVar "truth")) (EVar "plan")) (EApp (EApp (EApp (EApp (EVar "findFiniteHeight") (EVar "env")) (EVar "plan")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "finiteHeightLimit") (EVar "env")) (EVar "truth")) (EVar "plan"))) (EVar "None")))))
(DTypeSig false "finiteHeightLimit" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyCon "Int")))))
(DFunDef false "finiteHeightLimit" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" PWild (PVar "args")))) (EApp (EApp (EMethodRef "max") (ELit (LInt 1))) (EBinOp "+" (EApp (EVar "omSize") (EApp (EApp (EApp (EVar "reachableStates") (EVar "env")) (EVar "truth")) (EVar "nominal"))) (EApp (EApp (EVar "greatestWitnessBound") (EVar "env")) (EVar "args")))))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GInt")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GBool")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GFloat")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GChar")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GString")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GUnit")) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GList" PWild)) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GArray" PWild)) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GOption" PWild)) (ELit (LInt 0)))
(DFunDef false "finiteHeightLimit" ((PVar "env") PWild (PCon "GResult" (PVar "err") (PVar "ok"))) (EApp (EApp (EMethodRef "max") (EApp (EApp (EVar "witnessBound") (EVar "env")) (EVar "err"))) (EApp (EApp (EVar "witnessBound") (EVar "env")) (EVar "ok"))))
(DFunDef false "finiteHeightLimit" ((PVar "env") PWild (PCon "GTuple" (PVar "plans"))) (EApp (EApp (EVar "greatestWitnessBound") (EVar "env")) (EVar "plans")))
(DFunDef false "finiteHeightLimit" (PWild PWild (PCon "GCustom" PWild)) (ELit (LInt 0)))
(DTypeSig false "finiteTruth" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "finiteTruth" ((PVar "env") (PVar "root")) (EApp (EApp (EApp (EVar "finiteTruthLoop") (EVar "env")) (EVar "root")) (EVar "omEmpty")))
(DTypeSig false "finiteTruthLoop" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "finiteTruthLoop" ((PVar "env") (PVar "root") (PVar "truth")) (EBlock (DoLet false false (PVar "states") (EApp (EApp (EApp (EVar "reachableStates") (EVar "env")) (EVar "truth")) (EVar "root"))) (DoLet false false (PVar "next") (EApp (EApp (EApp (EApp (EVar "addFiniteStates") (EVar "env")) (EVar "truth")) (EVar "states")) (EVar "truth"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omSize") (EVar "next")) (EApp (EVar "omSize") (EVar "truth"))) (EVar "next") (EApp (EApp (EApp (EVar "finiteTruthLoop") (EVar "env")) (EVar "root")) (EVar "next"))))))
(DTypeSig false "addFiniteStates" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "addFiniteStates" ((PVar "env") (PVar "truth") (PVar "states") (PVar "result")) (EApp (EApp (EApp (EApp (EApp (EVar "addFiniteWords") (EVar "env")) (EVar "truth")) (EApp (EVar "omKeys") (EVar "states"))) (EVar "states")) (EVar "result")))
(DTypeSig false "addFiniteWords" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))
(DFunDef false "addFiniteWords" (PWild PWild (PList) PWild (PVar "result")) (EVar "result"))
(DFunDef false "addFiniteWords" ((PVar "env") (PVar "truth") (PCons (PVar "word") (PVar "rest")) (PVar "states") (PVar "result")) (EBlock (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "states")) (arm (PCon "Some" (PVar "state")) () (EIf (EApp (EApp (EApp (EVar "stateFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "state")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (ELit LUnit)) (EVar "result")) (EVar "result"))) (arm (PCon "None") () (EVar "result")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "addFiniteWords") (EVar "env")) (EVar "truth")) (EVar "rest")) (EVar "states")) (EVar "next")))))
(DTypeSig false "stateFiniteUnder" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyCon "Bool")))))
(DFunDef false "stateFiniteUnder" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild))) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EVar "anyCtorFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctors"))) (arm (PCon "Err" PWild) () (EVar "False"))))
(DFunDef false "stateFiniteUnder" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyCtorFiniteUnder" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyCon "Bool"))))))
(DFunDef false "anyCtorFiniteUnder" (PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyCtorFiniteUnder" ((PVar "env") (PVar "truth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EBinOp "||" (EApp (EApp (EApp (EVar "allFiniteUnder") (EVar "env")) (EVar "truth")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EApp (EApp (EApp (EApp (EVar "anyCtorFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EVar "anyCtorFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")))))
(DTypeSig false "allFiniteUnder" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool")))))
(DFunDef false "allFiniteUnder" (PWild PWild (PList)) (EVar "True"))
(DFunDef false "allFiniteUnder" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EVar "truth")) (EVar "plan")) (EApp (EApp (EApp (EVar "allFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "rest"))))
(DTypeSig false "abstractFinite" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyCon "Bool")))))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GInt")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GBool")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GFloat")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GChar")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GString")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GUnit")) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GList" PWild)) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GArray" PWild)) (EVar "True"))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GOption" PWild)) (EVar "True"))
(DFunDef false "abstractFinite" ((PVar "env") (PVar "truth") (PCon "GResult" (PVar "err") (PVar "ok"))) (EBinOp "||" (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EVar "truth")) (EVar "err")) (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EVar "truth")) (EVar "ok"))))
(DFunDef false "abstractFinite" ((PVar "env") (PVar "truth") (PCon "GTuple" (PVar "plans"))) (EApp (EApp (EApp (EVar "allFiniteUnder") (EVar "env")) (EVar "truth")) (EVar "plans")))
(DFunDef false "abstractFinite" (PWild PWild (PCon "GCustom" PWild)) (EVar "True"))
(DFunDef false "abstractFinite" ((PVar "env") (PVar "truth") (PCon "GNominal" (PVar "key") (PVar "args"))) (EApp (EApp (EVar "omHasKey") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (EVar "truth")))
(DTypeSig false "reachableStates" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyApp (TyCon "OrdMap") (TyCon "GenPlan"))))))
(DFunDef false "reachableStates" ((PVar "env") (PVar "truth") (PVar "root")) (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EListLit (EVar "root"))) (EApp (EApp (EApp (EApp (EVar "seedArgumentStates") (EVar "env")) (EVar "truth")) (EVar "root")) (EVar "omEmpty"))))
(DTypeSig false "seedArgumentStates" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyApp (TyCon "OrdMap") (TyCon "GenPlan")))))))
(DFunDef false "seedArgumentStates" ((PVar "env") (PVar "truth") (PCon "GNominal" PWild (PVar "args")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlans") (EVar "env")) (EVar "truth")) (EVar "args")) (EVar "states")))
(DFunDef false "seedArgumentStates" (PWild PWild PWild (PVar "states")) (EVar "states"))
(DTypeSig false "seedPlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyApp (TyCon "OrdMap") (TyCon "GenPlan")))))))
(DFunDef false "seedPlans" (PWild PWild (PList) (PVar "states")) (EVar "states"))
(DFunDef false "seedPlans" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlans") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "states"))))
(DTypeSig false "seedPlan" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyApp (TyCon "OrdMap") (TyCon "GenPlan")))))))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PCon "GList" (PVar "plan")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "states")))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PCon "GArray" (PVar "plan")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "states")))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PCon "GOption" (PVar "plan")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "states")))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "ok")) (EApp (EApp (EApp (EApp (EVar "seedPlan") (EVar "env")) (EVar "truth")) (EVar "err")) (EVar "states"))))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PCon "GTuple" (PVar "plans")) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlans") (EVar "env")) (EVar "truth")) (EVar "plans")) (EVar "states")))
(DFunDef false "seedPlan" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" (PVar "key") (PVar "args"))) (PVar "states")) (EApp (EApp (EApp (EApp (EVar "seedPlans") (EVar "env")) (EVar "truth")) (EVar "args")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (EVar "nominal")) (EVar "states"))))
(DFunDef false "seedPlan" (PWild PWild PWild (PVar "states")) (EVar "states"))
(DTypeSig false "discoverStates" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyApp (TyCon "OrdMap") (TyCon "GenPlan")))))))
(DFunDef false "discoverStates" (PWild PWild (PList) (PVar "states")) (EVar "states"))
(DFunDef false "discoverStates" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest")) (PVar "states")) (EMatch (EVar "plan") (arm (PCon "GList" (PVar "child")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EBinOp "::" (EVar "child") (EVar "rest"))) (EVar "states"))) (arm (PCon "GArray" (PVar "child")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EBinOp "::" (EVar "child") (EVar "rest"))) (EVar "states"))) (arm (PCon "GOption" (PVar "child")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EBinOp "::" (EVar "child") (EVar "rest"))) (EVar "states"))) (arm (PCon "GResult" (PVar "err") (PVar "ok")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EListLit (EVar "err") (EVar "ok"))) (EVar "states")))) (arm (PCon "GTuple" (PVar "plans")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "plans")) (EVar "states")))) (arm (PAs "nominal" (PCon "GNominal" (PVar "key") (PVar "args"))) () (EBlock (DoLet false false (PVar "word") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "states")) (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "seedPlans") (EVar "env")) (EVar "truth")) (EVar "args")) (EVar "states"))) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "discoverCtorFields") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "nominal")) (EVar "states"))))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "nominal")) (EVar "states"))))))))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EVar "rest")) (EVar "states")))))
(DTypeSig false "discoverCtorFields" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "GenPlan")) (TyApp (TyCon "OrdMap") (TyCon "GenPlan"))))))))
(DFunDef false "discoverCtorFields" (PWild PWild PWild (PList) (PVar "states")) (EVar "states"))
(DFunDef false "discoverCtorFields" ((PVar "env") (PVar "truth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PVar "states")) (EBlock (DoLet false false (PVar "afterCtor") (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "discoverStates") (EVar "env")) (EVar "truth")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EVar "states"))) (arm (PCon "Err" PWild) () (EVar "states")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "discoverCtorFields") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")) (EVar "afterCtor")))))
(DTypeSig false "stateWord" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "TypeKey") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "String"))))))
(DFunDef false "stateWord" ((PVar "env") (PVar "truth") (PVar "key") (PVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "typeKeyWord") (EVar "key")))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "stateBits") (EVar "env")) (EVar "truth")) (EVar "args")))) (ELit (LString ""))))
(DTypeSig false "stateBits" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "String")))))
(DFunDef false "stateBits" (PWild PWild (PList)) (ELit (LString "")))
(DFunDef false "stateBits" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest"))) (EBinOp "++" (EIf (EApp (EApp (EApp (EVar "abstractFinite") (EVar "env")) (EVar "truth")) (EVar "plan")) (ELit (LString "1")) (ELit (LString "0"))) (EApp (EApp (EApp (EVar "stateBits") (EVar "env")) (EVar "truth")) (EVar "rest"))))
(DTypeSig false "greatestWitnessBound" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Int"))))
(DFunDef false "greatestWitnessBound" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "greatestWitnessBound" ((PVar "env") (PCons (PVar "plan") (PVar "rest"))) (EApp (EApp (EMethodRef "max") (EApp (EApp (EVar "witnessBound") (EVar "env")) (EVar "plan"))) (EApp (EApp (EVar "greatestWitnessBound") (EVar "env")) (EVar "rest"))))
(DTypeSig false "witnessBound" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Int"))))
(DFunDef false "witnessBound" (PWild (PCon "GInt")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GBool")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GFloat")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GChar")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GString")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GUnit")) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GList" PWild)) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GArray" PWild)) (ELit (LInt 0)))
(DFunDef false "witnessBound" (PWild (PCon "GOption" PWild)) (ELit (LInt 0)))
(DFunDef false "witnessBound" ((PVar "env") (PCon "GResult" (PVar "err") (PVar "ok"))) (EApp (EApp (EMethodRef "max") (EApp (EApp (EVar "witnessBound") (EVar "env")) (EVar "err"))) (EApp (EApp (EVar "witnessBound") (EVar "env")) (EVar "ok"))))
(DFunDef false "witnessBound" ((PVar "env") (PCon "GTuple" (PVar "plans"))) (EApp (EApp (EVar "greatestWitnessBound") (EVar "env")) (EVar "plans")))
(DFunDef false "witnessBound" ((PVar "env") (PAs "nominal" (PCon "GNominal" PWild (PVar "args")))) (EBinOp "+" (EApp (EVar "omSize") (EApp (EApp (EApp (EVar "reachableStates") (EVar "env")) (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "nominal"))) (EVar "nominal"))) (EApp (EApp (EVar "greatestWitnessBound") (EVar "env")) (EVar "args"))))
(DFunDef false "witnessBound" (PWild (PCon "GCustom" PWild)) (ELit (LInt 0)))
(DTypeSig false "findFiniteHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "findFiniteHeight" (PWild PWild (PVar "height") (PVar "limit")) (EIf (EBinOp ">" (EVar "height") (EVar "limit")) (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "findFiniteHeight" ((PVar "env") (PVar "plan") (PVar "height") (PVar "limit")) (EIf (EApp (EApp (EApp (EVar "planFitsHeight") (EVar "env")) (EVar "plan")) (EVar "height")) (EApp (EVar "Some") (EVar "height")) (EApp (EApp (EApp (EApp (EVar "findFiniteHeight") (EVar "env")) (EVar "plan")) (EBinOp "+" (EVar "height") (ELit (LInt 1)))) (EVar "limit"))))
(DTypeSig false "planFitsHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "planFitsHeight" (PWild PWild (PVar "height")) (EIf (EBinOp "<" (EVar "height") (ELit (LInt 0))) (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "planFitsHeight" (PWild (PCon "GInt") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GBool") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GFloat") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GChar") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GString") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GUnit") PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GList" PWild) PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GArray" PWild) PWild) (EVar "True"))
(DFunDef false "planFitsHeight" (PWild (PCon "GOption" PWild) PWild) (EVar "True"))
(DFunDef false "planFitsHeight" ((PVar "env") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "height")) (EBinOp "||" (EApp (EApp (EApp (EVar "planFitsHeight") (EVar "env")) (EVar "err")) (EVar "height")) (EApp (EApp (EApp (EVar "planFitsHeight") (EVar "env")) (EVar "ok")) (EVar "height"))))
(DFunDef false "planFitsHeight" ((PVar "env") (PCon "GTuple" (PVar "plans")) (PVar "height")) (EApp (EApp (EApp (EVar "allPlansFitHeight") (EVar "env")) (EVar "plans")) (EVar "height")))
(DFunDef false "planFitsHeight" (PWild (PCon "GCustom" PWild) PWild) (EVar "True"))
(DFunDef false "planFitsHeight" ((PVar "env") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild)) (PVar "height")) (EIf (EBinOp "<=" (EVar "height") (ELit (LInt 0))) (EVar "False") (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EVar "anyCtorFitsHeight") (EVar "env")) (EVar "nominal")) (EVar "ctors")) (EBinOp "-" (EVar "height") (ELit (LInt 1))))) (arm (PCon "Err" PWild) () (EVar "False")))))
(DTypeSig false "anyCtorFitsHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "anyCtorFitsHeight" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyCtorFitsHeight" ((PVar "env") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PVar "height")) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EBinOp "||" (EApp (EApp (EApp (EVar "allPlansFitHeight") (EVar "env")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EVar "height")) (EApp (EApp (EApp (EApp (EVar "anyCtorFitsHeight") (EVar "env")) (EVar "nominal")) (EVar "rest")) (EVar "height")))) (arm (PCon "Err" PWild) () (EApp (EApp (EApp (EApp (EVar "anyCtorFitsHeight") (EVar "env")) (EVar "nominal")) (EVar "rest")) (EVar "height")))))
(DTypeSig false "allPlansFitHeight" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allPlansFitHeight" (PWild (PList) PWild) (EVar "True"))
(DFunDef false "allPlansFitHeight" ((PVar "env") (PCons (PVar "plan") (PVar "rest")) (PVar "height")) (EBinOp "&&" (EApp (EApp (EApp (EVar "planFitsHeight") (EVar "env")) (EVar "plan")) (EVar "height")) (EApp (EApp (EApp (EVar "allPlansFitHeight") (EVar "env")) (EVar "rest")) (EVar "height"))))
(DTypeSig false "allPlansFinite" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool"))))
(DFunDef false "allPlansFinite" (PWild (PList)) (EVar "True"))
(DFunDef false "allPlansFinite" ((PVar "env") (PCons (PVar "plan") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan")) (EApp (EApp (EVar "allPlansFinite") (EVar "env")) (EVar "rest"))))
(DTypeSig false "fieldPlansOnly" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "GenPlan"))) (TyApp (TyCon "List") (TyCon "GenPlan"))))
(DFunDef false "fieldPlansOnly" ((PList)) (EListLit))
(DFunDef false "fieldPlansOnly" ((PCons (PTuple PWild (PVar "plan")) (PVar "rest"))) (EBinOp "::" (EVar "plan") (EApp (EVar "fieldPlansOnly") (EVar "rest"))))
(DTypeSig false "allPlansBelow" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool")))))
(DFunDef false "allPlansBelow" (PWild PWild (PList)) (EVar "True"))
(DFunDef false "allPlansBelow" ((PVar "env") (PVar "height") (PCons (PVar "plan") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "planFiniteHeight") (EVar "env")) (EVar "plan")) (EListLit)) (arm (PCon "Some" (PVar "planHeight")) () (EBinOp "&&" (EBinOp "<" (EVar "planHeight") (EVar "height")) (EApp (EApp (EApp (EVar "allPlansBelow") (EVar "env")) (EVar "height")) (EVar "rest")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "planFor" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "GenPlan")))))))
(DFunDef false "planFor" ((PVar "env") (PVar "propName") (PVar "param") (PVar "ty")) (EMatch (EApp (EApp (EApp (EApp (EVar "planForGo") (EVar "env")) (EVar "propName")) (EVar "param")) (EVar "ty")) (arm (PCon "Ok" (PVar "plan")) () (EMatch (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "plan"))) (EVar "plan")) (EVar "omEmpty")) (arm (PCon "Err" (PCon "PlanError" PWild PWild (PVar "badTy") (PVar "reason") (PVar "detail"))) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "badTy")) (EVar "reason")) (EVar "detail")))) (arm (PCon "Ok" PWild) () (EIf (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan")) (EApp (EVar "Ok") (EVar "plan")) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "PlanError") (EVar "propName")) (EVar "param")) (EVar "ty")) (EVar "PENoFiniteValue")) (ELit (LString "no constructor path reaches finite values")))))))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "validateReachableFields" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "Unit")))))))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GInt") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GBool") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GFloat") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GChar") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GString") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GUnit") PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PCon "GList" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PCon "GArray" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PCon "GOption" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "seen")) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "err")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "ok")) (EVar "seen"))) (arm (PTuple (PCon "Ok" PWild) (PCon "Ok" PWild)) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PCon "GTuple" (PVar "plans")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachablePlans") (EVar "env")) (EVar "truth")) (EVar "plans")) (EVar "seen")))
(DFunDef false "validateReachableFields" (PWild PWild (PCon "GCustom" PWild) PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableFields" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" (PVar "key") (PVar "args"))) (PVar "seen")) (EBlock (DoLet false false (PVar "word") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "seen")) (EApp (EVar "Ok") (ELit LUnit)) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EApp (EVar "validateReachableCtors") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (ELit LUnit)) (EVar "seen")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))))))))
(DTypeSig false "validateReachablePlans" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "Unit")))))))
(DFunDef false "validateReachablePlans" (PWild PWild (PList) PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachablePlans" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest")) (PVar "seen")) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "validateReachableFields") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "validateReachablePlans") (EVar "env")) (EVar "truth")) (EVar "rest")) (EVar "seen"))) (arm (PTuple (PCon "Ok" PWild) (PCon "Ok" PWild)) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig false "validateReachableCtors" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyApp (TyCon "Result") (TyCon "PlanError")) (TyCon "Unit"))))))))
(DFunDef false "validateReachableCtors" (PWild PWild PWild (PList) PWild) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateReachableCtors" ((PVar "env") (PVar "truth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PVar "seen")) (EMatch (ETuple (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (EApp (EApp (EApp (EApp (EApp (EVar "validateReachableCtors") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")) (EVar "seen"))) (arm (PTuple (PCon "Ok" (PVar "fields")) (PCon "Ok" PWild)) () (EApp (EApp (EApp (EApp (EVar "validateReachablePlans") (EVar "env")) (EVar "truth")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EVar "seen"))) (arm (PTuple (PCon "Err" (PVar "e")) PWild) () (EApp (EVar "Err") (EVar "e"))) (arm (PTuple PWild (PCon "Err" (PVar "e"))) () (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "listLengthBound" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyCon "Int")))))
(DFunDef false "listLengthBound" ((PVar "env") (PVar "depth") (PVar "plan")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan"))) (ELit (LInt 0)) (EIf (EApp (EApp (EVar "planCyclesThroughList") (EVar "env")) (EVar "plan")) (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EBinOp "-" (EVar "listLenMax") (EVar "depth"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "plan"))) (ELit (LInt 0)) (EVar "listLenMax")))))
(DTypeSig true "listBoundDecays" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Bool"))))
(DFunDef false "listBoundDecays" ((PVar "env") (PVar "plan")) (EBinOp "&&" (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan")) (EApp (EApp (EVar "planCyclesThroughList") (EVar "env")) (EVar "plan"))))
(DTypeSig true "planCyclesThroughList" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Bool"))))
(DFunDef false "planCyclesThroughList" ((PVar "env") (PVar "plan")) (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "plan"))) (EVar "plan")) (EVar "omEmpty")) (ELit (LInt 0))))
(DTypeSig false "cyclesThroughListIn" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PCon "GList" (PVar "p")) (PVar "seen") (PVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "p")) (EVar "seen")) (EBinOp "+" (EVar "lists") (ELit (LInt 1)))))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PCon "GArray" (PVar "p")) (PVar "seen") (PVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "p")) (EVar "seen")) (EBinOp "+" (EVar "lists") (ELit (LInt 1)))))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PCon "GOption" (PVar "p")) (PVar "seen") (PVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "p")) (EVar "seen")) (EVar "lists")))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "seen") (PVar "lists")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "err")) (EVar "seen")) (EVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "ok")) (EVar "seen")) (EVar "lists"))))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PCon "GTuple" (PVar "ps")) (PVar "seen") (PVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "anyCyclesThroughList") (EVar "env")) (EVar "truth")) (EVar "ps")) (EVar "seen")) (EVar "lists")))
(DFunDef false "cyclesThroughListIn" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" (PVar "key") (PVar "args"))) (PVar "seen") (PVar "lists")) (EBlock (DoLet false false (PVar "word") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "word")) (EVar "seen")) (arm (PCon "Some" (PVar "entered")) () (EBinOp ">" (EVar "lists") (EVar "entered"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "anyCtorCyclesThroughList") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (EVar "lists")) (EVar "seen"))) (EVar "lists"))) (arm (PCon "Err" PWild) () (EVar "False"))))))))
(DFunDef false "cyclesThroughListIn" (PWild PWild PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyCyclesThroughList" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "anyCyclesThroughList" (PWild PWild (PList) PWild PWild) (EVar "False"))
(DFunDef false "anyCyclesThroughList" ((PVar "env") (PVar "truth") (PCons (PVar "p") (PVar "ps")) (PVar "seen") (PVar "lists")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "cyclesThroughListIn") (EVar "env")) (EVar "truth")) (EVar "p")) (EVar "seen")) (EVar "lists")) (EApp (EApp (EApp (EApp (EApp (EVar "anyCyclesThroughList") (EVar "env")) (EVar "truth")) (EVar "ps")) (EVar "seen")) (EVar "lists"))))
(DTypeSig false "anyCtorCyclesThroughList" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "anyCtorCyclesThroughList" (PWild PWild PWild (PList) PWild PWild) (EVar "False"))
(DFunDef false "anyCtorCyclesThroughList" ((PVar "env") (PVar "truth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PVar "seen") (PVar "lists")) (EBinOp "||" (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EApp (EVar "anyCyclesThroughList") (EVar "env")) (EVar "truth")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EVar "seen")) (EVar "lists"))) (arm (PCon "Err" PWild) () (EVar "False"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "anyCtorCyclesThroughList") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")) (EVar "seen")) (EVar "lists"))))
(DTypeSig true "optionWeights" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "optionWeights" ((PVar "env") (PVar "depth") (PVar "plan")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan"))) (EListLit (ELit (LInt 1)) (ELit (LInt 0))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "plan"))) (EListLit (ELit (LInt 1)) (ELit (LInt 0))) (EListLit (ELit (LInt 1)) (ELit (LInt 1))))))
(DTypeSig true "resultWeights" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "Int") (TyFun (TyCon "GenPlan") (TyFun (TyCon "GenPlan") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "resultWeights" ((PVar "env") (PVar "depth") (PVar "err") (PVar "ok")) (EIf (EBinOp ">=" (EVar "depth") (EVar "maxGenDepth")) (EListLit (EApp (EApp (EVar "boundPlanWeight") (EVar "env")) (EVar "err")) (EApp (EApp (EVar "boundPlanWeight") (EVar "env")) (EVar "ok"))) (EListLit (EApp (EApp (EVar "finitePlanWeight") (EVar "env")) (EVar "err")) (EApp (EApp (EVar "finitePlanWeight") (EVar "env")) (EVar "ok")))))
(DTypeSig false "finitePlanWeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Int"))))
(DFunDef false "finitePlanWeight" ((PVar "env") (PVar "plan")) (EIf (EApp (EApp (EVar "planHasFiniteValue") (EVar "env")) (EVar "plan")) (ELit (LInt 1)) (ELit (LInt 0))))
(DTypeSig false "boundPlanWeight" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Int"))))
(DFunDef false "boundPlanWeight" ((PVar "env") (PVar "plan")) (EIf (EApp (EApp (EVar "planCanFinishAtBound") (EVar "env")) (EVar "plan")) (ELit (LInt 1)) (ELit (LInt 0))))
(DTypeSig false "planCanFinishAtBound" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Bool"))))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GInt")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GBool")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GFloat")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GChar")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GString")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GUnit")) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GList" PWild)) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GArray" PWild)) (EVar "True"))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GOption" PWild)) (EVar "True"))
(DFunDef false "planCanFinishAtBound" ((PVar "env") (PCon "GResult" (PVar "err") (PVar "ok"))) (EBinOp "||" (EApp (EApp (EVar "planCanFinishAtBound") (EVar "env")) (EVar "err")) (EApp (EApp (EVar "planCanFinishAtBound") (EVar "env")) (EVar "ok"))))
(DFunDef false "planCanFinishAtBound" ((PVar "env") (PCon "GTuple" (PVar "plans"))) (EApp (EApp (EVar "allPlansFinishAtBound") (EVar "env")) (EVar "plans")))
(DFunDef false "planCanFinishAtBound" (PWild (PCon "GCustom" PWild)) (EVar "True"))
(DFunDef false "planCanFinishAtBound" ((PVar "env") (PAs "nominal" (PCon "GNominal" (PVar "key") PWild))) (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EVar "anyBoundCtor") (EVar "env")) (EVar "nominal")) (EVar "ctors"))) (arm (PCon "Err" PWild) () (EVar "False"))))
(DTypeSig false "anyBoundCtor" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyCon "Bool")))))
(DFunDef false "anyBoundCtor" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyBoundCtor" ((PVar "env") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "ctorLowersFiniteHeight") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (EApp (EApp (EApp (EVar "anyBoundCtor") (EVar "env")) (EVar "nominal")) (EVar "rest"))))
(DTypeSig false "allPlansFinishAtBound" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool"))))
(DFunDef false "allPlansFinishAtBound" (PWild (PList)) (EVar "True"))
(DFunDef false "allPlansFinishAtBound" ((PVar "env") (PCons (PVar "plan") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "planCanFinishAtBound") (EVar "env")) (EVar "plan")) (EApp (EApp (EVar "allPlansFinishAtBound") (EVar "env")) (EVar "rest"))))
(DTypeSig true "planCanDiverge" (TyFun (TyCon "PlanEnv") (TyFun (TyCon "GenPlan") (TyCon "Bool"))))
(DFunDef false "planCanDiverge" (PWild (PCon "GInt")) (EVar "False"))
(DFunDef false "planCanDiverge" (PWild (PCon "GBool")) (EVar "False"))
(DFunDef false "planCanDiverge" (PWild (PCon "GFloat")) (EVar "False"))
(DFunDef false "planCanDiverge" (PWild (PCon "GChar")) (EVar "False"))
(DFunDef false "planCanDiverge" (PWild (PCon "GString")) (EVar "False"))
(DFunDef false "planCanDiverge" (PWild (PCon "GUnit")) (EVar "False"))
(DFunDef false "planCanDiverge" ((PVar "env") (PCon "GList" (PVar "p"))) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "p")))
(DFunDef false "planCanDiverge" ((PVar "env") (PCon "GArray" (PVar "p"))) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "p")))
(DFunDef false "planCanDiverge" ((PVar "env") (PCon "GOption" (PVar "p"))) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "p")))
(DFunDef false "planCanDiverge" ((PVar "env") (PCon "GResult" (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "a")) (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "b"))))
(DFunDef false "planCanDiverge" ((PVar "env") (PCon "GTuple" (PVar "ps"))) (EApp (EApp (EVar "anyPlanDiverges") (EVar "env")) (EVar "ps")))
(DFunDef false "planCanDiverge" ((PVar "env") (PAs "nominal" (PCon "GNominal" PWild PWild))) (EApp (EApp (EApp (EApp (EVar "planCanDivergeNominal") (EVar "env")) (EApp (EApp (EVar "finiteTruth") (EVar "env")) (EVar "nominal"))) (EVar "nominal")) (EVar "omEmpty")))
(DFunDef false "planCanDiverge" (PWild (PCon "GCustom" PWild)) (EVar "False"))
(DTypeSig false "anyPlanDiverges" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyCon "Bool"))))
(DFunDef false "anyPlanDiverges" (PWild (PList)) (EVar "False"))
(DFunDef false "anyPlanDiverges" ((PVar "env") (PCons (PVar "p") (PVar "ps"))) (EBinOp "||" (EApp (EApp (EVar "planCanDiverge") (EVar "env")) (EVar "p")) (EApp (EApp (EVar "anyPlanDiverges") (EVar "env")) (EVar "ps"))))
(DTypeSig false "planCanDivergeNominal" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool"))))))
(DFunDef false "planCanDivergeNominal" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" (PVar "key") (PVar "args"))) (PVar "seen")) (EBlock (DoLet false false (PVar "word") (EApp (EApp (EApp (EApp (EVar "stateWord") (EVar "env")) (EVar "truth")) (EVar "key")) (EVar "args"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "word")) (EVar "seen")) (EVar "True") (EMatch (EApp (EApp (EVar "planDef") (EVar "env")) (EVar "key")) (arm (PCon "Ok" (PCon "PlanDef" PWild PWild PWild PWild (PVar "ctors"))) () (EApp (EApp (EApp (EApp (EApp (EVar "anyCtorPlanDiverges") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "word")) (ELit LUnit)) (EVar "seen")))) (arm (PCon "Err" PWild) () (EVar "False")))))))
(DFunDef false "planCanDivergeNominal" (PWild PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyCtorPlanDiverges" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "List") (TyCon "PlanCtor")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool")))))))
(DFunDef false "anyCtorPlanDiverges" (PWild PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyCtorPlanDiverges" ((PVar "env") (PVar "truth") (PVar "nominal") (PCons (PVar "ctor") (PVar "rest")) (PVar "seen")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "ctorPlanDiverges") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "ctor")) (EVar "seen")) (EApp (EApp (EApp (EApp (EApp (EVar "anyCtorPlanDiverges") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "rest")) (EVar "seen"))))
(DTypeSig false "ctorPlanDiverges" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyCon "PlanCtor") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool")))))))
(DFunDef false "ctorPlanDiverges" ((PVar "env") (PVar "truth") (PVar "nominal") (PVar "ctor") (PVar "seen")) (EMatch (EApp (EApp (EApp (EVar "instantiateCtor") (EVar "env")) (EVar "nominal")) (EVar "ctor")) (arm (PCon "Ok" (PVar "fields")) () (EApp (EApp (EApp (EApp (EVar "anyPlansDivergeSeen") (EVar "env")) (EVar "truth")) (EApp (EVar "fieldPlansOnly") (EVar "fields"))) (EVar "seen"))) (arm (PCon "Err" PWild) () (EVar "False"))))
(DTypeSig false "anyPlansDivergeSeen" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "GenPlan")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool"))))))
(DFunDef false "anyPlansDivergeSeen" (PWild PWild (PList) PWild) (EVar "False"))
(DFunDef false "anyPlansDivergeSeen" ((PVar "env") (PVar "truth") (PCons (PVar "plan") (PVar "rest")) (PVar "seen")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "anyPlansDivergeSeen") (EVar "env")) (EVar "truth")) (EVar "rest")) (EVar "seen"))))
(DTypeSig false "planDivergesSeen" (TyFun (TyCon "PlanEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GenPlan") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool"))))))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GInt") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GBool") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GFloat") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GChar") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GString") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GUnit") PWild) (EVar "False"))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PCon "GList" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PCon "GArray" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PCon "GOption" (PVar "plan")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "plan")) (EVar "seen")))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PCon "GResult" (PVar "err") (PVar "ok")) (PVar "seen")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "err")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "planDivergesSeen") (EVar "env")) (EVar "truth")) (EVar "ok")) (EVar "seen"))))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PCon "GTuple" (PVar "plans")) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "anyPlansDivergeSeen") (EVar "env")) (EVar "truth")) (EVar "plans")) (EVar "seen")))
(DFunDef false "planDivergesSeen" ((PVar "env") (PVar "truth") (PAs "nominal" (PCon "GNominal" PWild PWild)) (PVar "seen")) (EApp (EApp (EApp (EApp (EVar "planCanDivergeNominal") (EVar "env")) (EVar "truth")) (EVar "nominal")) (EVar "seen")))
(DFunDef false "planDivergesSeen" (PWild PWild (PCon "GCustom" PWild) PWild) (EVar "False"))
(DData Public "ShrinkAction" () ((variant "DeleteElements" (ConPos)) (variant "ShrinkChildren" (ConPos)) (variant "ReplaceEarlierNullary" (ConPos))) ())
(DTypeSig true "shrinkActions" (TyFun (TyCon "GenPlan") (TyApp (TyCon "List") (TyCon "ShrinkAction"))))
(DFunDef false "shrinkActions" ((PCon "GList" PWild)) (EListLit (EVar "DeleteElements") (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" ((PCon "GArray" PWild)) (EListLit (EVar "DeleteElements") (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" ((PCon "GTuple" PWild)) (EListLit (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" ((PCon "GOption" PWild)) (EListLit (EVar "ReplaceEarlierNullary") (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" ((PCon "GResult" PWild PWild)) (EListLit (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" ((PCon "GNominal" PWild PWild)) (EListLit (EVar "ReplaceEarlierNullary") (EVar "ShrinkChildren")))
(DFunDef false "shrinkActions" (PWild) (EListLit))
(DData Public "IntShrinkStep" () ((variant "IntToZero" (ConPos)) (variant "IntHalf" (ConPos)) (variant "IntTowardZero" (ConPos))) ())
(DTypeSig true "intShrinkSteps" (TyApp (TyCon "List") (TyCon "IntShrinkStep")))
(DFunDef false "intShrinkSteps" () (EListLit (EVar "IntToZero") (EVar "IntHalf") (EVar "IntTowardZero")))
