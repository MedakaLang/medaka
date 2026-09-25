# META
source_lines=250
stages=DESUGAR,MARK
# SOURCE
-- Produced values join at positive positions. This is neither type equality
-- nor a permission to widen an existing invariant container. Callers supply
-- inference services and declaration-derived variance; rows are only collected.
import types.repr.{Mono(..), Tyvar(..), normalize}
import types.effect_rows.{EffRow}
import types.effect_domain.{Param}
import types.effect_authority.{Authority, authDomainTop}
import support.util.{minI, anyList}

public export data ValueJoinOps c = ValueJoinOps {
  vjoEqual : c -> Mono -> Mono -> Unit,
  vjoCovariants : Mono -> List Bool,
  vjoFreshType : Unit -> Mono,
  vjoFreshRow : Unit -> EffRow,
  vjoCollectRows : List EffRow -> EffRow,
  -- A positive qualified slot receives an allowance bounded below by every
  -- alternative's authority, the authority peer of a row allowance.
  vjoFreshAuth : Param -> Authority,
  vjoCollectAuth : List Authority -> Authority,
}

export
joinProduced : ValueJoinOps c -> List (c, Mono) -> Option Mono
joinProduced _ [] = None
joinProduced _ [(_, value)] = Some value
joinProduced ops values = Some (joinNonempty ops values)

-- A binding envelope must visit even a single producer: its collector allocates
-- owned summaries at positive arrows instead of aliasing the producer's rows.
export
joinProducedEnvelope : ValueJoinOps c -> List (c, Mono) -> Option Mono
joinProducedEnvelope _ [] = None
joinProducedEnvelope ops values = Some (joinNonempty ops values)

-- Shape an unknown alternative without copying the witness's closed rows.
-- Otherwise `if flag then callback else pureFn` would first make callback pure.
shapeUnknown : ValueJoinOps c -> Mono -> (c, Mono) -> (c, Mono)
shapeUnknown ops witness (context, value) =
  let _ = match normalize value
    TVar cell => match cell.value
      Unbound id _ =>
        if occursIn id witness then
          ()  -- matchingValues reports the occurs equation once, then omits it.
        else
          ops.vjoEqual context value (freshShape ops witness)
      Link _ => ()
    _ => ()
  (context, normalize value)

freshShape : ValueJoinOps c -> Mono -> Mono
freshShape ops (TFun _ _ _) =
  TFun (ops.vjoFreshType ()) (ops.vjoFreshRow ()) (ops.vjoFreshType ())
freshShape ops (TApp head _) =
  TApp (freshApplicationHead ops head) (ops.vjoFreshType ())
freshShape ops (TEff _) = TEff (ops.vjoFreshRow ())
freshShape ops (TQual inner q) =
  TQual (freshShape ops inner) (ops.vjoFreshAuth (authDomainTop q))
freshShape _ t = t

freshApplicationHead : ValueJoinOps c -> Mono -> Mono
freshApplicationHead ops head = match normalize head
  TApp prefix _ => TApp (freshApplicationHead ops prefix) (ops.vjoFreshType ())
  _ => ops.vjoFreshType ()

-- Shaping must not hide an infinite-type equation from ordinary unification.
-- In particular x joined with Box x must report an occurs-check failure.
occursIn : Int -> Mono -> Bool
occursIn id value = match normalize value
  TVar cell => match cell.value
    Unbound other _ => id == other
    Link _ => False
  TFun domain _ result => occursIn id domain || occursIn id result
  TApp head argument => occursIn id head || occursIn id argument
  TQual inner _ => occursIn id inner
  _ => False

concreteWitness : List (c, Mono) -> Option Mono
concreteWitness [] = None
concreteWitness ((_, t) :: rest) = match normalize t
  TVar _ => concreteWitness rest
  value => Some value

sameShape : Mono -> Mono -> Bool
sameShape (TFun _ _ _) (TFun _ _ _) = True
sameShape (TApp _ _) (TApp _ _) = True
sameShape (TQual _ _) (TQual _ _) = True
sameShape _ _ = False

-- An incompatible alternative is diagnosed through ordinary equality, then
-- omitted from recovery. No user type mismatch reaches a projection panic.
matchingValues : ValueJoinOps c -> Mono -> List (c, Mono) -> List (c, Mono)
matchingValues _ _ [] = []
matchingValues ops witness ((value@(context, t)) :: rest) =
  if sameShape witness t then
    value :: matchingValues ops witness rest
  else
    let _ = ops.vjoEqual context witness t
    matchingValues ops witness rest

joinNonempty : ValueJoinOps c -> List (c, Mono) -> Mono
joinNonempty ops values = match concreteWitness values
  None => equalValues ops values
  Some witness => match witness
    TFun _ _ _ =>
      let alternatives =
        matchingValues ops witness (map (shapeUnknown ops witness) values)
      let domain = equalValues ops (map arrowDomain alternatives)
      let rows = map arrowRow alternatives
      let result = joinNonempty ops (map arrowResult alternatives)
      TFun domain (ops.vjoCollectRows rows) result
    TApp _ _ =>
      let alternatives =
        matchingValues ops witness (map (shapeUnknown ops witness) values)
      joinApplications ops alternatives
    -- Qualified alternatives join their value types and take one allowance
    -- above every authority.  A plain alternative beside them is a value the
    -- domain cannot bound, so the join forgets the qualifier: only the
    -- expression-directed abstraction can recover more, and it does.
    TQual _ _ =>
      let shaped = map (shapeUnknown ops witness) values
      if anyList (v => not (isQualified (snd v))) shaped then
        joinNonempty ops (map (v => (fst v, qualInner (snd v))) shaped)
      else
        let inner =
          joinNonempty ops (map (v => (fst v, qualInner (snd v))) shaped)
        TQual inner (ops.vjoCollectAuth (map (v => qualAuth (snd v)) shaped))
    _ =>
      -- Concrete heads and effect indices have no covariant join rule.
      equalValues ops values

equalValues : ValueJoinOps c -> List (c, Mono) -> Mono
equalValues _ [] = panic "empty produced-value equality"
equalValues ops ((_, first) :: rest) =
  let _ = equalRest ops first rest
  first

equalRest : ValueJoinOps c -> Mono -> List (c, Mono) -> Unit
equalRest _ _ [] = ()
equalRest ops first ((context, value) :: rest) =
  let _ = ops.vjoEqual context first value
  equalRest ops first rest

arrowDomain : (c, Mono) -> (c, Mono)
arrowDomain (context, TFun domain _ _) = (context, domain)
arrowDomain _ = panic "non-arrow produced-value projection"

arrowRow : (c, Mono) -> EffRow
arrowRow (_, TFun _ row _) = row
arrowRow _ = panic "non-arrow produced-value projection"

arrowResult : (c, Mono) -> (c, Mono)
arrowResult (context, TFun _ _ result) = (context, result)
arrowResult _ = panic "non-arrow produced-value projection"

-- Flatten the common application suffix once. A higher-kinded unknown prefix
-- may unify with a partially applied constructor; its arguments are not lost.
joinApplications : ValueJoinOps c -> List (c, Mono) -> Mono
joinApplications ops values =
  let arity = commonArity values
  let spines = map (applicationSpine arity) values
  let head =
    equalValues ops (map (entry => (fst entry, fst (snd entry))) spines)
  let args = map (entry => (fst entry, snd (snd entry))) spines
  joinArguments ops head (ops.vjoCovariants head) args

applicationDepth : Mono -> Int
applicationDepth value = match normalize value
  TApp head _ => 1 + applicationDepth head
  _ => 0

commonArity : List (c, Mono) -> Int
commonArity [] = 0
commonArity [(_, value)] = applicationDepth value
commonArity ((_, value) :: rest) =
  minI (applicationDepth value) (commonArity rest)

applicationSpine : Int -> (c, Mono) -> (c, (Mono, List Mono))
applicationSpine arity (context, value) =
  (context, peelApplication arity value [])

peelApplication : Int -> Mono -> List Mono -> (Mono, List Mono)
peelApplication arity value args =
  if arity == 0 then
    (value, args)
  else match normalize value
    TApp head argument => peelApplication (arity - 1) head (argument :: args)
    _ => panic "produced-value application spine changed arity"

joinArguments : ValueJoinOps c ->
  Mono ->
  List Bool ->
  List (c, List Mono) ->
  Mono
joinArguments ops head modes (rows@((_, _ :: _) :: _)) =
  let values = map argumentFirst rows
  let argument = match modes
    True :: _ => joinNonempty ops values
    _ => equalValues ops values
  let restModes = match modes
    _ :: rest => rest
    [] => []
  joinArguments ops (TApp head argument) restModes (map argumentRest rows)
joinArguments _ head _ _ = head

argumentFirst : (c, List Mono) -> (c, Mono)
argumentFirst (context, first :: _) = (context, first)
argumentFirst _ = panic "empty produced-value argument column"

argumentRest : (c, List Mono) -> (c, List Mono)
argumentRest (context, _ :: rest) = (context, rest)
argumentRest _ = panic "empty produced-value argument column"

-- Every callable reachable through positive projections exposes its domain to
-- callers. Invariant/unknown constructor slots are not projected through.
export
producedInputTypes : (Mono -> List Bool) -> Mono -> List Mono
producedInputTypes variance value = inputTypesGo variance value []

inputTypesGo : (Mono -> List Bool) -> Mono -> List Mono -> List Mono
inputTypesGo variance value acc = match normalize value
  TFun domain _ result => inputTypesGo variance result (domain :: acc)
  TApp _ _ =>
    let (head, arguments) = peelApplication (applicationDepth value) value []
    inputArguments variance (variance head) arguments acc
  _ => acc

inputArguments : (Mono -> List Bool) ->
  List Bool ->
  List Mono ->
  List Mono ->
  List Mono
inputArguments variance (mode :: modes) (argument :: arguments) acc =
  let next = if mode then inputTypesGo variance argument acc else acc
  inputArguments variance modes arguments next
inputArguments _ _ _ acc = acc

isQualified : Mono -> Bool
isQualified value = match normalize value
  TQual _ _ => True
  _ => False

qualInner : Mono -> Mono
qualInner value = match normalize value
  TQual inner _ => inner
  other => other

qualAuth : Mono -> Authority
qualAuth value = match normalize value
  TQual _ q => q
  _ => panic "qualified-value join projected a plain alternative"
# DESUGAR
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" false) (mem "authDomainTop" false))))
(DUse false (UseGroup ("support" "util") ((mem "minI" false) (mem "anyList" false))))
(DData Public "ValueJoinOps" ("c") ((variant "ValueJoinOps" (ConNamed (field "vjoEqual" (TyFun (TyVar "c") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))) (field "vjoCovariants" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Bool")))) (field "vjoFreshType" (TyFun (TyCon "Unit") (TyCon "Mono"))) (field "vjoFreshRow" (TyFun (TyCon "Unit") (TyCon "EffRow"))) (field "vjoCollectRows" (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))) (field "vjoFreshAuth" (TyFun (TyCon "Param") (TyCon "Authority"))) (field "vjoCollectAuth" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Authority")))))) ())
(DTypeSig true "joinProduced" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "joinProduced" (PWild (PList)) (EVar "None"))
(DFunDef false "joinProduced" (PWild (PList (PTuple PWild (PVar "value")))) (EApp (EVar "Some") (EVar "value")))
(DFunDef false "joinProduced" ((PVar "ops") (PVar "values")) (EApp (EVar "Some") (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EVar "values"))))
(DTypeSig true "joinProducedEnvelope" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "joinProducedEnvelope" (PWild (PList)) (EVar "None"))
(DFunDef false "joinProducedEnvelope" ((PVar "ops") (PVar "values")) (EApp (EVar "Some") (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EVar "values"))))
(DTypeSig false "shapeUnknown" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyFun (TyTuple (TyVar "c") (TyCon "Mono")) (TyTuple (TyVar "c") (TyCon "Mono"))))))
(DFunDef false "shapeUnknown" ((PVar "ops") (PVar "witness") (PTuple (PVar "context") (PVar "value"))) (EBlock (DoLet false false PWild (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EFieldAccess (EVar "cell") "value") (arm (PCon "Unbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "witness")) (ELit LUnit) (EApp (EApp (EApp (EFieldAccess (EVar "ops") "vjoEqual") (EVar "context")) (EVar "value")) (EApp (EApp (EVar "freshShape") (EVar "ops")) (EVar "witness"))))) (arm (PCon "Link" PWild) () (ELit LUnit)))) (arm PWild () (ELit LUnit)))) (DoExpr (ETuple (EVar "context") (EApp (EVar "normalize") (EVar "value"))))))
(DTypeSig false "freshShape" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "freshShape" ((PVar "ops") (PCon "TFun" PWild PWild PWild)) (EApp (EApp (EApp (EVar "TFun") (EApp (EFieldAccess (EVar "ops") "vjoFreshType") (ELit LUnit))) (EApp (EFieldAccess (EVar "ops") "vjoFreshRow") (ELit LUnit))) (EApp (EFieldAccess (EVar "ops") "vjoFreshType") (ELit LUnit))))
(DFunDef false "freshShape" ((PVar "ops") (PCon "TApp" (PVar "head") PWild)) (EApp (EApp (EVar "TApp") (EApp (EApp (EVar "freshApplicationHead") (EVar "ops")) (EVar "head"))) (EApp (EFieldAccess (EVar "ops") "vjoFreshType") (ELit LUnit))))
(DFunDef false "freshShape" ((PVar "ops") (PCon "TEff" PWild)) (EApp (EVar "TEff") (EApp (EFieldAccess (EVar "ops") "vjoFreshRow") (ELit LUnit))))
(DFunDef false "freshShape" ((PVar "ops") (PCon "TQual" (PVar "inner") (PVar "q"))) (EApp (EApp (EVar "TQual") (EApp (EApp (EVar "freshShape") (EVar "ops")) (EVar "inner"))) (EApp (EFieldAccess (EVar "ops") "vjoFreshAuth") (EApp (EVar "authDomainTop") (EVar "q")))))
(DFunDef false "freshShape" (PWild (PVar "t")) (EVar "t"))
(DTypeSig false "freshApplicationHead" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "freshApplicationHead" ((PVar "ops") (PVar "head")) (EMatch (EApp (EVar "normalize") (EVar "head")) (arm (PCon "TApp" (PVar "prefix") PWild) () (EApp (EApp (EVar "TApp") (EApp (EApp (EVar "freshApplicationHead") (EVar "ops")) (EVar "prefix"))) (EApp (EFieldAccess (EVar "ops") "vjoFreshType") (ELit LUnit)))) (arm PWild () (EApp (EFieldAccess (EVar "ops") "vjoFreshType") (ELit LUnit)))))
(DTypeSig false "occursIn" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "occursIn" ((PVar "id") (PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EFieldAccess (EVar "cell") "value") (arm (PCon "Unbound" (PVar "other") PWild) () (EBinOp "==" (EVar "id") (EVar "other"))) (arm (PCon "Link" PWild) () (EVar "False")))) (arm (PCon "TFun" (PVar "domain") PWild (PVar "result")) () (EBinOp "||" (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "domain")) (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "result")))) (arm (PCon "TApp" (PVar "head") (PVar "argument")) () (EBinOp "||" (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "head")) (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "argument")))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "inner"))) (arm PWild () (EVar "False"))))
(DTypeSig false "concreteWitness" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono"))))
(DFunDef false "concreteWitness" ((PList)) (EVar "None"))
(DFunDef false "concreteWitness" ((PCons (PTuple PWild (PVar "t")) (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" PWild) () (EApp (EVar "concreteWitness") (EVar "rest"))) (arm (PVar "value") () (EApp (EVar "Some") (EVar "value")))))
(DTypeSig false "sameShape" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "sameShape" ((PCon "TFun" PWild PWild PWild) (PCon "TFun" PWild PWild PWild)) (EVar "True"))
(DFunDef false "sameShape" ((PCon "TApp" PWild PWild) (PCon "TApp" PWild PWild)) (EVar "True"))
(DFunDef false "sameShape" ((PCon "TQual" PWild PWild) (PCon "TQual" PWild PWild)) (EVar "True"))
(DFunDef false "sameShape" (PWild PWild) (EVar "False"))
(DTypeSig false "matchingValues" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono")))))))
(DFunDef false "matchingValues" (PWild PWild (PList)) (EListLit))
(DFunDef false "matchingValues" ((PVar "ops") (PVar "witness") (PCons (PAs "value" (PTuple (PVar "context") (PVar "t"))) (PVar "rest"))) (EIf (EApp (EApp (EVar "sameShape") (EVar "witness")) (EVar "t")) (EBinOp "::" (EVar "value") (EApp (EApp (EApp (EVar "matchingValues") (EVar "ops")) (EVar "witness")) (EVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EFieldAccess (EVar "ops") "vjoEqual") (EVar "context")) (EVar "witness")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EVar "matchingValues") (EVar "ops")) (EVar "witness")) (EVar "rest"))))))
(DTypeSig false "joinNonempty" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyCon "Mono"))))
(DFunDef false "joinNonempty" ((PVar "ops") (PVar "values")) (EMatch (EApp (EVar "concreteWitness") (EVar "values")) (arm (PCon "None") () (EApp (EApp (EVar "equalValues") (EVar "ops")) (EVar "values"))) (arm (PCon "Some" (PVar "witness")) () (EMatch (EVar "witness") (arm (PCon "TFun" PWild PWild PWild) () (EBlock (DoLet false false (PVar "alternatives") (EApp (EApp (EApp (EVar "matchingValues") (EVar "ops")) (EVar "witness")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "shapeUnknown") (EVar "ops")) (EVar "witness"))) (EVar "values")))) (DoLet false false (PVar "domain") (EApp (EApp (EVar "equalValues") (EVar "ops")) (EApp (EApp (EVar "map") (EVar "arrowDomain")) (EVar "alternatives")))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "map") (EVar "arrowRow")) (EVar "alternatives"))) (DoLet false false (PVar "result") (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EApp (EApp (EVar "map") (EVar "arrowResult")) (EVar "alternatives")))) (DoExpr (EApp (EApp (EApp (EVar "TFun") (EVar "domain")) (EApp (EFieldAccess (EVar "ops") "vjoCollectRows") (EVar "rows"))) (EVar "result"))))) (arm (PCon "TApp" PWild PWild) () (EBlock (DoLet false false (PVar "alternatives") (EApp (EApp (EApp (EVar "matchingValues") (EVar "ops")) (EVar "witness")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "shapeUnknown") (EVar "ops")) (EVar "witness"))) (EVar "values")))) (DoExpr (EApp (EApp (EVar "joinApplications") (EVar "ops")) (EVar "alternatives"))))) (arm (PCon "TQual" PWild PWild) () (EBlock (DoLet false false (PVar "shaped") (EApp (EApp (EVar "map") (EApp (EApp (EVar "shapeUnknown") (EVar "ops")) (EVar "witness"))) (EVar "values"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EVar "isQualified") (EApp (EVar "snd") (EVar "v")))))) (EVar "shaped")) (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "fst") (EVar "v")) (EApp (EVar "qualInner") (EApp (EVar "snd") (EVar "v")))))) (EVar "shaped"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "fst") (EVar "v")) (EApp (EVar "qualInner") (EApp (EVar "snd") (EVar "v")))))) (EVar "shaped")))) (DoExpr (EApp (EApp (EVar "TQual") (EVar "inner")) (EApp (EFieldAccess (EVar "ops") "vjoCollectAuth") (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EApp (EVar "qualAuth") (EApp (EVar "snd") (EVar "v"))))) (EVar "shaped")))))))))) (arm PWild () (EApp (EApp (EVar "equalValues") (EVar "ops")) (EVar "values")))))))
(DTypeSig false "equalValues" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyCon "Mono"))))
(DFunDef false "equalValues" (PWild (PList)) (EApp (EVar "panic") (ELit (LString "empty produced-value equality"))))
(DFunDef false "equalValues" ((PVar "ops") (PCons (PTuple PWild (PVar "first")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "equalRest") (EVar "ops")) (EVar "first")) (EVar "rest"))) (DoExpr (EVar "first"))))
(DTypeSig false "equalRest" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "equalRest" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "equalRest" ((PVar "ops") (PVar "first") (PCons (PTuple (PVar "context") (PVar "value")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EFieldAccess (EVar "ops") "vjoEqual") (EVar "context")) (EVar "first")) (EVar "value"))) (DoExpr (EApp (EApp (EApp (EVar "equalRest") (EVar "ops")) (EVar "first")) (EVar "rest")))))
(DTypeSig false "arrowDomain" (TyFun (TyTuple (TyVar "c") (TyCon "Mono")) (TyTuple (TyVar "c") (TyCon "Mono"))))
(DFunDef false "arrowDomain" ((PTuple (PVar "context") (PCon "TFun" (PVar "domain") PWild PWild))) (ETuple (EVar "context") (EVar "domain")))
(DFunDef false "arrowDomain" (PWild) (EApp (EVar "panic") (ELit (LString "non-arrow produced-value projection"))))
(DTypeSig false "arrowRow" (TyFun (TyTuple (TyVar "c") (TyCon "Mono")) (TyCon "EffRow")))
(DFunDef false "arrowRow" ((PTuple PWild (PCon "TFun" PWild (PVar "row") PWild))) (EVar "row"))
(DFunDef false "arrowRow" (PWild) (EApp (EVar "panic") (ELit (LString "non-arrow produced-value projection"))))
(DTypeSig false "arrowResult" (TyFun (TyTuple (TyVar "c") (TyCon "Mono")) (TyTuple (TyVar "c") (TyCon "Mono"))))
(DFunDef false "arrowResult" ((PTuple (PVar "context") (PCon "TFun" PWild PWild (PVar "result")))) (ETuple (EVar "context") (EVar "result")))
(DFunDef false "arrowResult" (PWild) (EApp (EVar "panic") (ELit (LString "non-arrow produced-value projection"))))
(DTypeSig false "joinApplications" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyCon "Mono"))))
(DFunDef false "joinApplications" ((PVar "ops") (PVar "values")) (EBlock (DoLet false false (PVar "arity") (EApp (EVar "commonArity") (EVar "values"))) (DoLet false false (PVar "spines") (EApp (EApp (EVar "map") (EApp (EVar "applicationSpine") (EVar "arity"))) (EVar "values"))) (DoLet false false (PVar "head") (EApp (EApp (EVar "equalValues") (EVar "ops")) (EApp (EApp (EVar "map") (ELam ((PVar "entry")) (ETuple (EApp (EVar "fst") (EVar "entry")) (EApp (EVar "fst") (EApp (EVar "snd") (EVar "entry")))))) (EVar "spines")))) (DoLet false false (PVar "args") (EApp (EApp (EVar "map") (ELam ((PVar "entry")) (ETuple (EApp (EVar "fst") (EVar "entry")) (EApp (EVar "snd") (EApp (EVar "snd") (EVar "entry")))))) (EVar "spines"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "joinArguments") (EVar "ops")) (EVar "head")) (EApp (EFieldAccess (EVar "ops") "vjoCovariants") (EVar "head"))) (EVar "args")))))
(DTypeSig false "applicationDepth" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "applicationDepth" ((PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TApp" (PVar "head") PWild) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "applicationDepth") (EVar "head")))) (arm PWild () (ELit (LInt 0)))))
(DTypeSig false "commonArity" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyCon "Int")))
(DFunDef false "commonArity" ((PList)) (ELit (LInt 0)))
(DFunDef false "commonArity" ((PList (PTuple PWild (PVar "value")))) (EApp (EVar "applicationDepth") (EVar "value")))
(DFunDef false "commonArity" ((PCons (PTuple PWild (PVar "value")) (PVar "rest"))) (EApp (EApp (EVar "minI") (EApp (EVar "applicationDepth") (EVar "value"))) (EApp (EVar "commonArity") (EVar "rest"))))
(DTypeSig false "applicationSpine" (TyFun (TyCon "Int") (TyFun (TyTuple (TyVar "c") (TyCon "Mono")) (TyTuple (TyVar "c") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "applicationSpine" ((PVar "arity") (PTuple (PVar "context") (PVar "value"))) (ETuple (EVar "context") (EApp (EApp (EApp (EVar "peelApplication") (EVar "arity")) (EVar "value")) (EListLit))))
(DTypeSig false "peelApplication" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "peelApplication" ((PVar "arity") (PVar "value") (PVar "args")) (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 0))) (ETuple (EVar "value") (EVar "args")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TApp" (PVar "head") (PVar "argument")) () (EApp (EApp (EApp (EVar "peelApplication") (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "head")) (EBinOp "::" (EVar "argument") (EVar "args")))) (arm PWild () (EApp (EVar "panic") (ELit (LString "produced-value application spine changed arity")))))))
(DTypeSig false "joinArguments" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyApp (TyCon "List") (TyCon "Mono")))) (TyCon "Mono"))))))
(DFunDef false "joinArguments" ((PVar "ops") (PVar "head") (PVar "modes") (PAs "rows" (PCons (PTuple PWild (PCons PWild PWild)) PWild))) (EBlock (DoLet false false (PVar "values") (EApp (EApp (EVar "map") (EVar "argumentFirst")) (EVar "rows"))) (DoLet false false (PVar "argument") (EMatch (EVar "modes") (arm (PCons (PCon "True") PWild) () (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EVar "values"))) (arm PWild () (EApp (EApp (EVar "equalValues") (EVar "ops")) (EVar "values"))))) (DoLet false false (PVar "restModes") (EMatch (EVar "modes") (arm (PCons PWild (PVar "rest")) () (EVar "rest")) (arm (PList) () (EListLit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "joinArguments") (EVar "ops")) (EApp (EApp (EVar "TApp") (EVar "head")) (EVar "argument"))) (EVar "restModes")) (EApp (EApp (EVar "map") (EVar "argumentRest")) (EVar "rows"))))))
(DFunDef false "joinArguments" (PWild (PVar "head") PWild PWild) (EVar "head"))
(DTypeSig false "argumentFirst" (TyFun (TyTuple (TyVar "c") (TyApp (TyCon "List") (TyCon "Mono"))) (TyTuple (TyVar "c") (TyCon "Mono"))))
(DFunDef false "argumentFirst" ((PTuple (PVar "context") (PCons (PVar "first") PWild))) (ETuple (EVar "context") (EVar "first")))
(DFunDef false "argumentFirst" (PWild) (EApp (EVar "panic") (ELit (LString "empty produced-value argument column"))))
(DTypeSig false "argumentRest" (TyFun (TyTuple (TyVar "c") (TyApp (TyCon "List") (TyCon "Mono"))) (TyTuple (TyVar "c") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "argumentRest" ((PTuple (PVar "context") (PCons PWild (PVar "rest")))) (ETuple (EVar "context") (EVar "rest")))
(DFunDef false "argumentRest" (PWild) (EApp (EVar "panic") (ELit (LString "empty produced-value argument column"))))
(DTypeSig true "producedInputTypes" (TyFun (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Bool"))) (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "producedInputTypes" ((PVar "variance") (PVar "value")) (EApp (EApp (EApp (EVar "inputTypesGo") (EVar "variance")) (EVar "value")) (EListLit)))
(DTypeSig false "inputTypesGo" (TyFun (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Bool"))) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "inputTypesGo" ((PVar "variance") (PVar "value") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TFun" (PVar "domain") PWild (PVar "result")) () (EApp (EApp (EApp (EVar "inputTypesGo") (EVar "variance")) (EVar "result")) (EBinOp "::" (EVar "domain") (EVar "acc")))) (arm (PCon "TApp" PWild PWild) () (EBlock (DoLet false false (PTuple (PVar "head") (PVar "arguments")) (EApp (EApp (EApp (EVar "peelApplication") (EApp (EVar "applicationDepth") (EVar "value"))) (EVar "value")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inputArguments") (EVar "variance")) (EApp (EVar "variance") (EVar "head"))) (EVar "arguments")) (EVar "acc"))))) (arm PWild () (EVar "acc"))))
(DTypeSig false "inputArguments" (TyFun (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "inputArguments" ((PVar "variance") (PCons (PVar "mode") (PVar "modes")) (PCons (PVar "argument") (PVar "arguments")) (PVar "acc")) (EBlock (DoLet false false (PVar "next") (EIf (EVar "mode") (EApp (EApp (EApp (EVar "inputTypesGo") (EVar "variance")) (EVar "argument")) (EVar "acc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inputArguments") (EVar "variance")) (EVar "modes")) (EVar "arguments")) (EVar "next")))))
(DFunDef false "inputArguments" (PWild PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "isQualified" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "isQualified" ((PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TQual" PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "qualInner" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "qualInner" ((PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TQual" (PVar "inner") PWild) () (EVar "inner")) (arm (PVar "other") () (EVar "other"))))
(DTypeSig false "qualAuth" (TyFun (TyCon "Mono") (TyCon "Authority")))
(DFunDef false "qualAuth" ((PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TQual" PWild (PVar "q")) () (EVar "q")) (arm PWild () (EApp (EVar "panic") (ELit (LString "qualified-value join projected a plain alternative"))))))
# MARK
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" false) (mem "authDomainTop" false))))
(DUse false (UseGroup ("support" "util") ((mem "minI" false) (mem "anyList" false))))
(DData Public "ValueJoinOps" ("c") ((variant "ValueJoinOps" (ConNamed (field "vjoEqual" (TyFun (TyVar "c") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))) (field "vjoCovariants" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Bool")))) (field "vjoFreshType" (TyFun (TyCon "Unit") (TyCon "Mono"))) (field "vjoFreshRow" (TyFun (TyCon "Unit") (TyCon "EffRow"))) (field "vjoCollectRows" (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))) (field "vjoFreshAuth" (TyFun (TyCon "Param") (TyCon "Authority"))) (field "vjoCollectAuth" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Authority")))))) ())
(DTypeSig true "joinProduced" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "joinProduced" (PWild (PList)) (EVar "None"))
(DFunDef false "joinProduced" (PWild (PList (PTuple PWild (PVar "value")))) (EApp (EVar "Some") (EVar "value")))
(DFunDef false "joinProduced" ((PVar "ops") (PVar "values")) (EApp (EVar "Some") (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EVar "values"))))
(DTypeSig true "joinProducedEnvelope" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "joinProducedEnvelope" (PWild (PList)) (EVar "None"))
(DFunDef false "joinProducedEnvelope" ((PVar "ops") (PVar "values")) (EApp (EVar "Some") (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EVar "values"))))
(DTypeSig false "shapeUnknown" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyFun (TyTuple (TyVar "c") (TyCon "Mono")) (TyTuple (TyVar "c") (TyCon "Mono"))))))
(DFunDef false "shapeUnknown" ((PVar "ops") (PVar "witness") (PTuple (PVar "context") (PVar "value"))) (EBlock (DoLet false false PWild (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EFieldAccess (EVar "cell") "value") (arm (PCon "Unbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "witness")) (ELit LUnit) (EApp (EApp (EApp (EFieldAccess (EVar "ops") "vjoEqual") (EVar "context")) (EVar "value")) (EApp (EApp (EVar "freshShape") (EVar "ops")) (EVar "witness"))))) (arm (PCon "Link" PWild) () (ELit LUnit)))) (arm PWild () (ELit LUnit)))) (DoExpr (ETuple (EVar "context") (EApp (EVar "normalize") (EVar "value"))))))
(DTypeSig false "freshShape" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "freshShape" ((PVar "ops") (PCon "TFun" PWild PWild PWild)) (EApp (EApp (EApp (EVar "TFun") (EApp (EFieldAccess (EVar "ops") "vjoFreshType") (ELit LUnit))) (EApp (EFieldAccess (EVar "ops") "vjoFreshRow") (ELit LUnit))) (EApp (EFieldAccess (EVar "ops") "vjoFreshType") (ELit LUnit))))
(DFunDef false "freshShape" ((PVar "ops") (PCon "TApp" (PVar "head") PWild)) (EApp (EApp (EVar "TApp") (EApp (EApp (EVar "freshApplicationHead") (EVar "ops")) (EVar "head"))) (EApp (EFieldAccess (EVar "ops") "vjoFreshType") (ELit LUnit))))
(DFunDef false "freshShape" ((PVar "ops") (PCon "TEff" PWild)) (EApp (EVar "TEff") (EApp (EFieldAccess (EVar "ops") "vjoFreshRow") (ELit LUnit))))
(DFunDef false "freshShape" ((PVar "ops") (PCon "TQual" (PVar "inner") (PVar "q"))) (EApp (EApp (EVar "TQual") (EApp (EApp (EVar "freshShape") (EVar "ops")) (EVar "inner"))) (EApp (EFieldAccess (EVar "ops") "vjoFreshAuth") (EApp (EVar "authDomainTop") (EVar "q")))))
(DFunDef false "freshShape" (PWild (PVar "t")) (EVar "t"))
(DTypeSig false "freshApplicationHead" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "freshApplicationHead" ((PVar "ops") (PVar "head")) (EMatch (EApp (EVar "normalize") (EVar "head")) (arm (PCon "TApp" (PVar "prefix") PWild) () (EApp (EApp (EVar "TApp") (EApp (EApp (EVar "freshApplicationHead") (EVar "ops")) (EVar "prefix"))) (EApp (EFieldAccess (EVar "ops") "vjoFreshType") (ELit LUnit)))) (arm PWild () (EApp (EFieldAccess (EVar "ops") "vjoFreshType") (ELit LUnit)))))
(DTypeSig false "occursIn" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "occursIn" ((PVar "id") (PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EFieldAccess (EVar "cell") "value") (arm (PCon "Unbound" (PVar "other") PWild) () (EBinOp "==" (EVar "id") (EVar "other"))) (arm (PCon "Link" PWild) () (EVar "False")))) (arm (PCon "TFun" (PVar "domain") PWild (PVar "result")) () (EBinOp "||" (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "domain")) (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "result")))) (arm (PCon "TApp" (PVar "head") (PVar "argument")) () (EBinOp "||" (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "head")) (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "argument")))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EVar "occursIn") (EVar "id")) (EVar "inner"))) (arm PWild () (EVar "False"))))
(DTypeSig false "concreteWitness" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono"))))
(DFunDef false "concreteWitness" ((PList)) (EVar "None"))
(DFunDef false "concreteWitness" ((PCons (PTuple PWild (PVar "t")) (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" PWild) () (EApp (EVar "concreteWitness") (EVar "rest"))) (arm (PVar "value") () (EApp (EVar "Some") (EVar "value")))))
(DTypeSig false "sameShape" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "sameShape" ((PCon "TFun" PWild PWild PWild) (PCon "TFun" PWild PWild PWild)) (EVar "True"))
(DFunDef false "sameShape" ((PCon "TApp" PWild PWild) (PCon "TApp" PWild PWild)) (EVar "True"))
(DFunDef false "sameShape" ((PCon "TQual" PWild PWild) (PCon "TQual" PWild PWild)) (EVar "True"))
(DFunDef false "sameShape" (PWild PWild) (EVar "False"))
(DTypeSig false "matchingValues" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono")))))))
(DFunDef false "matchingValues" (PWild PWild (PList)) (EListLit))
(DFunDef false "matchingValues" ((PVar "ops") (PVar "witness") (PCons (PAs "value" (PTuple (PVar "context") (PVar "t"))) (PVar "rest"))) (EIf (EApp (EApp (EVar "sameShape") (EVar "witness")) (EVar "t")) (EBinOp "::" (EVar "value") (EApp (EApp (EApp (EVar "matchingValues") (EVar "ops")) (EVar "witness")) (EVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EFieldAccess (EVar "ops") "vjoEqual") (EVar "context")) (EVar "witness")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EVar "matchingValues") (EVar "ops")) (EVar "witness")) (EVar "rest"))))))
(DTypeSig false "joinNonempty" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyCon "Mono"))))
(DFunDef false "joinNonempty" ((PVar "ops") (PVar "values")) (EMatch (EApp (EVar "concreteWitness") (EVar "values")) (arm (PCon "None") () (EApp (EApp (EVar "equalValues") (EVar "ops")) (EVar "values"))) (arm (PCon "Some" (PVar "witness")) () (EMatch (EVar "witness") (arm (PCon "TFun" PWild PWild PWild) () (EBlock (DoLet false false (PVar "alternatives") (EApp (EApp (EApp (EVar "matchingValues") (EVar "ops")) (EVar "witness")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "shapeUnknown") (EVar "ops")) (EVar "witness"))) (EVar "values")))) (DoLet false false (PVar "domain") (EApp (EApp (EVar "equalValues") (EVar "ops")) (EApp (EApp (EMethodRef "map") (EVar "arrowDomain")) (EVar "alternatives")))) (DoLet false false (PVar "rows") (EApp (EApp (EMethodRef "map") (EVar "arrowRow")) (EVar "alternatives"))) (DoLet false false (PVar "result") (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EApp (EApp (EMethodRef "map") (EVar "arrowResult")) (EVar "alternatives")))) (DoExpr (EApp (EApp (EApp (EVar "TFun") (EVar "domain")) (EApp (EFieldAccess (EVar "ops") "vjoCollectRows") (EVar "rows"))) (EVar "result"))))) (arm (PCon "TApp" PWild PWild) () (EBlock (DoLet false false (PVar "alternatives") (EApp (EApp (EApp (EVar "matchingValues") (EVar "ops")) (EVar "witness")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "shapeUnknown") (EVar "ops")) (EVar "witness"))) (EVar "values")))) (DoExpr (EApp (EApp (EVar "joinApplications") (EVar "ops")) (EVar "alternatives"))))) (arm (PCon "TQual" PWild PWild) () (EBlock (DoLet false false (PVar "shaped") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "shapeUnknown") (EVar "ops")) (EVar "witness"))) (EVar "values"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EVar "isQualified") (EApp (EVar "snd") (EVar "v")))))) (EVar "shaped")) (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "fst") (EVar "v")) (EApp (EVar "qualInner") (EApp (EVar "snd") (EVar "v")))))) (EVar "shaped"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "fst") (EVar "v")) (EApp (EVar "qualInner") (EApp (EVar "snd") (EVar "v")))))) (EVar "shaped")))) (DoExpr (EApp (EApp (EVar "TQual") (EVar "inner")) (EApp (EFieldAccess (EVar "ops") "vjoCollectAuth") (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EApp (EVar "qualAuth") (EApp (EVar "snd") (EVar "v"))))) (EVar "shaped")))))))))) (arm PWild () (EApp (EApp (EVar "equalValues") (EVar "ops")) (EVar "values")))))))
(DTypeSig false "equalValues" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyCon "Mono"))))
(DFunDef false "equalValues" (PWild (PList)) (EApp (EVar "panic") (ELit (LString "empty produced-value equality"))))
(DFunDef false "equalValues" ((PVar "ops") (PCons (PTuple PWild (PVar "first")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "equalRest") (EVar "ops")) (EVar "first")) (EVar "rest"))) (DoExpr (EVar "first"))))
(DTypeSig false "equalRest" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "equalRest" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "equalRest" ((PVar "ops") (PVar "first") (PCons (PTuple (PVar "context") (PVar "value")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EFieldAccess (EVar "ops") "vjoEqual") (EVar "context")) (EVar "first")) (EVar "value"))) (DoExpr (EApp (EApp (EApp (EVar "equalRest") (EVar "ops")) (EVar "first")) (EVar "rest")))))
(DTypeSig false "arrowDomain" (TyFun (TyTuple (TyVar "c") (TyCon "Mono")) (TyTuple (TyVar "c") (TyCon "Mono"))))
(DFunDef false "arrowDomain" ((PTuple (PVar "context") (PCon "TFun" (PVar "domain") PWild PWild))) (ETuple (EVar "context") (EVar "domain")))
(DFunDef false "arrowDomain" (PWild) (EApp (EVar "panic") (ELit (LString "non-arrow produced-value projection"))))
(DTypeSig false "arrowRow" (TyFun (TyTuple (TyVar "c") (TyCon "Mono")) (TyCon "EffRow")))
(DFunDef false "arrowRow" ((PTuple PWild (PCon "TFun" PWild (PVar "row") PWild))) (EVar "row"))
(DFunDef false "arrowRow" (PWild) (EApp (EVar "panic") (ELit (LString "non-arrow produced-value projection"))))
(DTypeSig false "arrowResult" (TyFun (TyTuple (TyVar "c") (TyCon "Mono")) (TyTuple (TyVar "c") (TyCon "Mono"))))
(DFunDef false "arrowResult" ((PTuple (PVar "context") (PCon "TFun" PWild PWild (PVar "result")))) (ETuple (EVar "context") (EVar "result")))
(DFunDef false "arrowResult" (PWild) (EApp (EVar "panic") (ELit (LString "non-arrow produced-value projection"))))
(DTypeSig false "joinApplications" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyCon "Mono"))))
(DFunDef false "joinApplications" ((PVar "ops") (PVar "values")) (EBlock (DoLet false false (PVar "arity") (EApp (EVar "commonArity") (EVar "values"))) (DoLet false false (PVar "spines") (EApp (EApp (EMethodRef "map") (EApp (EVar "applicationSpine") (EVar "arity"))) (EVar "values"))) (DoLet false false (PVar "head") (EApp (EApp (EVar "equalValues") (EVar "ops")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "entry")) (ETuple (EApp (EVar "fst") (EVar "entry")) (EApp (EVar "fst") (EApp (EVar "snd") (EVar "entry")))))) (EVar "spines")))) (DoLet false false (PVar "args") (EApp (EApp (EMethodRef "map") (ELam ((PVar "entry")) (ETuple (EApp (EVar "fst") (EVar "entry")) (EApp (EVar "snd") (EApp (EVar "snd") (EVar "entry")))))) (EVar "spines"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "joinArguments") (EVar "ops")) (EVar "head")) (EApp (EFieldAccess (EVar "ops") "vjoCovariants") (EVar "head"))) (EVar "args")))))
(DTypeSig false "applicationDepth" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "applicationDepth" ((PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TApp" (PVar "head") PWild) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "applicationDepth") (EVar "head")))) (arm PWild () (ELit (LInt 0)))))
(DTypeSig false "commonArity" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyCon "Mono"))) (TyCon "Int")))
(DFunDef false "commonArity" ((PList)) (ELit (LInt 0)))
(DFunDef false "commonArity" ((PList (PTuple PWild (PVar "value")))) (EApp (EVar "applicationDepth") (EVar "value")))
(DFunDef false "commonArity" ((PCons (PTuple PWild (PVar "value")) (PVar "rest"))) (EApp (EApp (EVar "minI") (EApp (EVar "applicationDepth") (EVar "value"))) (EApp (EVar "commonArity") (EVar "rest"))))
(DTypeSig false "applicationSpine" (TyFun (TyCon "Int") (TyFun (TyTuple (TyVar "c") (TyCon "Mono")) (TyTuple (TyVar "c") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "applicationSpine" ((PVar "arity") (PTuple (PVar "context") (PVar "value"))) (ETuple (EVar "context") (EApp (EApp (EApp (EVar "peelApplication") (EVar "arity")) (EVar "value")) (EListLit))))
(DTypeSig false "peelApplication" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "peelApplication" ((PVar "arity") (PVar "value") (PVar "args")) (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 0))) (ETuple (EVar "value") (EVar "args")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TApp" (PVar "head") (PVar "argument")) () (EApp (EApp (EApp (EVar "peelApplication") (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "head")) (EBinOp "::" (EVar "argument") (EVar "args")))) (arm PWild () (EApp (EVar "panic") (ELit (LString "produced-value application spine changed arity")))))))
(DTypeSig false "joinArguments" (TyFun (TyApp (TyCon "ValueJoinOps") (TyVar "c")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "c") (TyApp (TyCon "List") (TyCon "Mono")))) (TyCon "Mono"))))))
(DFunDef false "joinArguments" ((PVar "ops") (PVar "head") (PVar "modes") (PAs "rows" (PCons (PTuple PWild (PCons PWild PWild)) PWild))) (EBlock (DoLet false false (PVar "values") (EApp (EApp (EMethodRef "map") (EVar "argumentFirst")) (EVar "rows"))) (DoLet false false (PVar "argument") (EMatch (EVar "modes") (arm (PCons (PCon "True") PWild) () (EApp (EApp (EVar "joinNonempty") (EVar "ops")) (EVar "values"))) (arm PWild () (EApp (EApp (EVar "equalValues") (EVar "ops")) (EVar "values"))))) (DoLet false false (PVar "restModes") (EMatch (EVar "modes") (arm (PCons PWild (PVar "rest")) () (EVar "rest")) (arm (PList) () (EListLit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "joinArguments") (EVar "ops")) (EApp (EApp (EVar "TApp") (EVar "head")) (EVar "argument"))) (EVar "restModes")) (EApp (EApp (EMethodRef "map") (EVar "argumentRest")) (EVar "rows"))))))
(DFunDef false "joinArguments" (PWild (PVar "head") PWild PWild) (EVar "head"))
(DTypeSig false "argumentFirst" (TyFun (TyTuple (TyVar "c") (TyApp (TyCon "List") (TyCon "Mono"))) (TyTuple (TyVar "c") (TyCon "Mono"))))
(DFunDef false "argumentFirst" ((PTuple (PVar "context") (PCons (PVar "first") PWild))) (ETuple (EVar "context") (EVar "first")))
(DFunDef false "argumentFirst" (PWild) (EApp (EVar "panic") (ELit (LString "empty produced-value argument column"))))
(DTypeSig false "argumentRest" (TyFun (TyTuple (TyVar "c") (TyApp (TyCon "List") (TyCon "Mono"))) (TyTuple (TyVar "c") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "argumentRest" ((PTuple (PVar "context") (PCons PWild (PVar "rest")))) (ETuple (EVar "context") (EVar "rest")))
(DFunDef false "argumentRest" (PWild) (EApp (EVar "panic") (ELit (LString "empty produced-value argument column"))))
(DTypeSig true "producedInputTypes" (TyFun (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Bool"))) (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "producedInputTypes" ((PVar "variance") (PVar "value")) (EApp (EApp (EApp (EVar "inputTypesGo") (EVar "variance")) (EVar "value")) (EListLit)))
(DTypeSig false "inputTypesGo" (TyFun (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Bool"))) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "inputTypesGo" ((PVar "variance") (PVar "value") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TFun" (PVar "domain") PWild (PVar "result")) () (EApp (EApp (EApp (EVar "inputTypesGo") (EVar "variance")) (EVar "result")) (EBinOp "::" (EVar "domain") (EVar "acc")))) (arm (PCon "TApp" PWild PWild) () (EBlock (DoLet false false (PTuple (PVar "head") (PVar "arguments")) (EApp (EApp (EApp (EVar "peelApplication") (EApp (EVar "applicationDepth") (EVar "value"))) (EVar "value")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inputArguments") (EVar "variance")) (EApp (EVar "variance") (EVar "head"))) (EVar "arguments")) (EVar "acc"))))) (arm PWild () (EVar "acc"))))
(DTypeSig false "inputArguments" (TyFun (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "inputArguments" ((PVar "variance") (PCons (PVar "mode") (PVar "modes")) (PCons (PVar "argument") (PVar "arguments")) (PVar "acc")) (EBlock (DoLet false false (PVar "next") (EIf (EVar "mode") (EApp (EApp (EApp (EVar "inputTypesGo") (EVar "variance")) (EVar "argument")) (EVar "acc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inputArguments") (EVar "variance")) (EVar "modes")) (EVar "arguments")) (EVar "next")))))
(DFunDef false "inputArguments" (PWild PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "isQualified" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "isQualified" ((PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TQual" PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "qualInner" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "qualInner" ((PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TQual" (PVar "inner") PWild) () (EVar "inner")) (arm (PVar "other") () (EVar "other"))))
(DTypeSig false "qualAuth" (TyFun (TyCon "Mono") (TyCon "Authority")))
(DFunDef false "qualAuth" ((PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TQual" PWild (PVar "q")) () (EVar "q")) (arm PWild () (EApp (EVar "panic") (ELit (LString "qualified-value join projected a plain alternative"))))))
