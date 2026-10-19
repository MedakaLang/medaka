# META
source_lines=211
stages=DESUGAR,MARK
# SOURCE
-- What each source binder holds at run time, as the typechecker decided it.
--
-- The typechecker publishes ONE table per elaboration, keyed by the `BinderId`
-- every binder node carries (`frontend/ast.mdk`): lambda and clause parameters,
-- `let` and match binders, as-pattern and record-pun binders, where/let-group
-- functions and top-level function clauses.  A row is read after the graph-end
-- drain, so after Num defaulting and after every unification any module could
-- still make, and it is MATERIALIZED there: a row holds a `RuntimeType`, never
-- a `Mono`, because a memoized prelude graph shares its type cells with later
-- elaborations and a stored cell could be read back as some other program's type.
--
-- The lookup lives here, beside `route_key.mdk` and `disposition.mdk`, for the
-- same reason theirs do: `types/` cannot import `ir/`, and the reader that
-- needs it (`ir/core_ir_lower.mdk`) cannot import a typechecker-private cell.
--
-- Interface default bodies are typechecked once but lowered once per instance,
-- so a Core binder cloned from one maps many-to-one onto a single row here.
-- That is consistent only because such a binder is typed at the interface's own
-- type variable, which this domain renders as `RTValue` for every instance.

import frontend.ast.{BinderId(..), TyConOrigin(..)}
import types.repr.{Mono(..), Tyvar(..)}
import map.{Map(..), get, set}

-- The runtime-type domain.  Each case is a distinction some emitter draws today
-- by recovering it from the program's shape; the table states it instead.  The
-- domain is deliberately not physical: no boxed/unboxed split, no register or
-- wasm reference kinds.  Those are backend decisions made FROM this fact.
--
-- `RTCon` is a constructor cell: a value of a `data` or `newtype` type, a list
-- or a tuple.  `RTValue` is everything the type alone does not pin to one of the
-- other cases: a type variable (so a polymorphic binder, whose representation
-- is the caller's), a rigid variable, a function or closure, and an opaque
-- runtime object (`Ref`, `Array`, an `extern data` type).  It is the answer
-- "no static fact", never a guess at one, and there is deliberately no
-- numeric-but-unknown case: a `Num a =>` binder's arithmetic dispatches through
-- its dictionary, and that is all an emitter can do with it.
public export data RuntimeType =
  | RTInt
  | RTFloat
  | RTBool
  | RTChar
  | RTString
  | RTUnit
  | RTU64
  | RTI64
  | RTU32
  | RTI32
  | RTU16
  | RTU8
  | RTCon
  | RTValue
  deriving (Eq, Debug)

-- One published binder.  The name is the binder's source spelling, carried as a
-- tripwire and for diagnostics, never as a key.  `brReturns` is `Some` for a
-- function binder (a where/let-group member or a top-level clause): its own row
-- is the function's type, which is `RTValue` whenever it takes parameters, and
-- what its body returns after its declared parameters is a second fact.  Every
-- clause of a multi-clause function carries the function's one return type.
-- `brSigned` is whether the source function has a declared type signature: an
-- inferred type and a declared one stamp alike, and a backend that gives only
-- declared functions a different calling convention needs to tell them apart.
public export data BinderRow = BinderRow {
  brId : BinderId,
  brName : String,
  brType : RuntimeType,
  brReturns : Option RuntimeType,
  brSigned : Bool,
}

-- The table, keyed by the id's ordinal.  Ordinals come from one process-global
-- counter, so the ordinal alone is unique; the module half is compared on every
-- hit (`binderRowIn`).
export type BinderTypeTable = Map Int BinderRow

export
emptyBinderTypes : BinderTypeTable
emptyBinderTypes = Tip

-- Add [row] under its ordinal.  An ordinal the table already holds is
-- overwritten: the same binder recorded twice by one elaboration names the same
-- type cell both times.
export
addBinderRow : BinderRow -> BinderTypeTable -> BinderTypeTable
addBinderRow row table = set (binderOrdinal row.brId) row table

-- The ordinal of [bid], which no other binder in the process shares.
export
binderOrdinal : BinderId -> Int
binderOrdinal (BinderId _ i) = i

-- The runtime type of a binder whose (solved) type is [t].  [isCell] answers
-- whether a non-builtin type constructor, by name and origin, is a `data` or
-- `newtype` declaration rather than an opaque `extern data` one; the
-- typechecker answers it from the graph's declarations.
--
-- A builtin head is read by name only under `OriginBuiltin`: a same-spelled head
-- with any other origin is a different type, and the conservative answer for it
-- is `RTValue`.
--
-- >>> runtimeTypeOf (_ _ => False) (TCon "Float" OriginBuiltin)
-- RTFloat
-- >>> runtimeTypeOf (_ _ => False) (TCon "Float" (OriginModule "m"))
-- RTValue
export
runtimeTypeOf : (String -> TyConOrigin -> Bool) -> Mono -> RuntimeType
runtimeTypeOf isCell (TVar cell) = match !cell
  Link t => runtimeTypeOf isCell t
  Unbound _ _ => RTValue
runtimeTypeOf isCell (TQual inner _) = runtimeTypeOf isCell inner
runtimeTypeOf isCell (TCon n o) = headRuntimeType isCell n o
runtimeTypeOf isCell (TApp f _) = appliedRuntimeType isCell f
runtimeTypeOf _ _ = RTValue

-- An applied type is a cell when its head is; a scalar head never takes
-- arguments, and a variable head (`f a`) fixes nothing.
appliedRuntimeType : (String -> TyConOrigin -> Bool) -> Mono -> RuntimeType
appliedRuntimeType isCell (TVar cell) = match !cell
  Link t => appliedRuntimeType isCell t
  Unbound _ _ => RTValue
appliedRuntimeType isCell (TQual inner _) = appliedRuntimeType isCell inner
appliedRuntimeType isCell (TApp f _) = appliedRuntimeType isCell f
appliedRuntimeType isCell (TCon n o) = match headRuntimeType isCell n o
  RTCon => RTCon
  _ => RTValue
appliedRuntimeType _ _ = RTValue

headRuntimeType : (String -> TyConOrigin -> Bool) ->
  String ->
  TyConOrigin ->
  RuntimeType
headRuntimeType _ n OriginBuiltin = builtinRuntimeType n
headRuntimeType isCell n o = if isCell n o then RTCon else RTValue

builtinRuntimeType : String -> RuntimeType
builtinRuntimeType "Int" = RTInt
builtinRuntimeType "Float" = RTFloat
builtinRuntimeType "Bool" = RTBool
builtinRuntimeType "Char" = RTChar
builtinRuntimeType "String" = RTString
builtinRuntimeType "Unit" = RTUnit
builtinRuntimeType "U64" = RTU64
builtinRuntimeType "I64" = RTI64
builtinRuntimeType "U32" = RTU32
builtinRuntimeType "I32" = RTI32
builtinRuntimeType "U16" = RTU16
builtinRuntimeType "U8" = RTU8
builtinRuntimeType "List" = RTCon
builtinRuntimeType "__tuple2__" = RTCon
builtinRuntimeType "__tuple3__" = RTCon
builtinRuntimeType "__tuple4__" = RTCon
builtinRuntimeType "__tuple5__" = RTCon
builtinRuntimeType _ = RTValue

-- The row [table] holds for [bid], or `None` when the typechecker recorded none for
-- it; no table answers `None`.  A row answering for a different module than the id
-- names is a panic: ordinals are never reused within a process, so it can only
-- mean the module half was rewritten without the ordinal.
export
binderRowIn : Option BinderTypeTable -> BinderId -> Option BinderRow
binderRowIn None _ = None
binderRowIn (Some table) (BinderId m i) = rowIn table m i

rowIn : BinderTypeTable -> String -> Int -> Option BinderRow
rowIn table m i = match get i table
  None => None
  Some row => match row.brId
    BinderId m2 _ =>
      if m2 == m then
        Some row
      else
        panic "binder table: \{m}#\{intToString i} answered by module \{m2}"

-- The spelling a row's type has in a Core dump (`core_ir_sexp`), and its inverse.
-- Both are explicit tables, not derived `Debug`, so that Core dumps and the
-- goldens that pin them do not depend on how `Debug` spells a constructor.
export
runtimeTypeName : RuntimeType -> String
runtimeTypeName RTInt = "RTInt"
runtimeTypeName RTFloat = "RTFloat"
runtimeTypeName RTBool = "RTBool"
runtimeTypeName RTChar = "RTChar"
runtimeTypeName RTString = "RTString"
runtimeTypeName RTUnit = "RTUnit"
runtimeTypeName RTU64 = "RTU64"
runtimeTypeName RTI64 = "RTI64"
runtimeTypeName RTU32 = "RTU32"
runtimeTypeName RTI32 = "RTI32"
runtimeTypeName RTU16 = "RTU16"
runtimeTypeName RTU8 = "RTU8"
runtimeTypeName RTCon = "RTCon"
runtimeTypeName RTValue = "RTValue"

export
runtimeTypeFromName : String -> Option RuntimeType
runtimeTypeFromName "RTInt" = Some RTInt
runtimeTypeFromName "RTFloat" = Some RTFloat
runtimeTypeFromName "RTBool" = Some RTBool
runtimeTypeFromName "RTChar" = Some RTChar
runtimeTypeFromName "RTString" = Some RTString
runtimeTypeFromName "RTUnit" = Some RTUnit
runtimeTypeFromName "RTU64" = Some RTU64
runtimeTypeFromName "RTI64" = Some RTI64
runtimeTypeFromName "RTU32" = Some RTU32
runtimeTypeFromName "RTI32" = Some RTI32
runtimeTypeFromName "RTU16" = Some RTU16
runtimeTypeFromName "RTU8" = Some RTU8
runtimeTypeFromName "RTCon" = Some RTCon
runtimeTypeFromName "RTValue" = Some RTValue
runtimeTypeFromName _ = None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true))))
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "get" false) (mem "set" false))))
(DData Public "RuntimeType" () ((variant "RTInt" (ConPos)) (variant "RTFloat" (ConPos)) (variant "RTBool" (ConPos)) (variant "RTChar" (ConPos)) (variant "RTString" (ConPos)) (variant "RTUnit" (ConPos)) (variant "RTU64" (ConPos)) (variant "RTI64" (ConPos)) (variant "RTU32" (ConPos)) (variant "RTI32" (ConPos)) (variant "RTU16" (ConPos)) (variant "RTU8" (ConPos)) (variant "RTCon" (ConPos)) (variant "RTValue" (ConPos))) ())
(DImpl true "Eq" ((TyCon "RuntimeType")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RTInt") (PCon "RTInt")) () (EVar "True")) (arm (PTuple (PCon "RTFloat") (PCon "RTFloat")) () (EVar "True")) (arm (PTuple (PCon "RTBool") (PCon "RTBool")) () (EVar "True")) (arm (PTuple (PCon "RTChar") (PCon "RTChar")) () (EVar "True")) (arm (PTuple (PCon "RTString") (PCon "RTString")) () (EVar "True")) (arm (PTuple (PCon "RTUnit") (PCon "RTUnit")) () (EVar "True")) (arm (PTuple (PCon "RTU64") (PCon "RTU64")) () (EVar "True")) (arm (PTuple (PCon "RTI64") (PCon "RTI64")) () (EVar "True")) (arm (PTuple (PCon "RTU32") (PCon "RTU32")) () (EVar "True")) (arm (PTuple (PCon "RTI32") (PCon "RTI32")) () (EVar "True")) (arm (PTuple (PCon "RTU16") (PCon "RTU16")) () (EVar "True")) (arm (PTuple (PCon "RTU8") (PCon "RTU8")) () (EVar "True")) (arm (PTuple (PCon "RTCon") (PCon "RTCon")) () (EVar "True")) (arm (PTuple (PCon "RTValue") (PCon "RTValue")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "RuntimeType")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RTInt") () (ELit (LString "RTInt"))) (arm (PCon "RTFloat") () (ELit (LString "RTFloat"))) (arm (PCon "RTBool") () (ELit (LString "RTBool"))) (arm (PCon "RTChar") () (ELit (LString "RTChar"))) (arm (PCon "RTString") () (ELit (LString "RTString"))) (arm (PCon "RTUnit") () (ELit (LString "RTUnit"))) (arm (PCon "RTU64") () (ELit (LString "RTU64"))) (arm (PCon "RTI64") () (ELit (LString "RTI64"))) (arm (PCon "RTU32") () (ELit (LString "RTU32"))) (arm (PCon "RTI32") () (ELit (LString "RTI32"))) (arm (PCon "RTU16") () (ELit (LString "RTU16"))) (arm (PCon "RTU8") () (ELit (LString "RTU8"))) (arm (PCon "RTCon") () (ELit (LString "RTCon"))) (arm (PCon "RTValue") () (ELit (LString "RTValue")))))))
(DData Public "BinderRow" () ((variant "BinderRow" (ConNamed (field "brId" (TyCon "BinderId")) (field "brName" (TyCon "String")) (field "brType" (TyCon "RuntimeType")) (field "brReturns" (TyApp (TyCon "Option") (TyCon "RuntimeType"))) (field "brSigned" (TyCon "Bool"))))) ())
(DTypeAlias true "BinderTypeTable" () (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "BinderRow")))
(DTypeSig true "emptyBinderTypes" (TyCon "BinderTypeTable"))
(DFunDef false "emptyBinderTypes" () (EVar "Tip"))
(DTypeSig true "addBinderRow" (TyFun (TyCon "BinderRow") (TyFun (TyCon "BinderTypeTable") (TyCon "BinderTypeTable"))))
(DFunDef false "addBinderRow" ((PVar "row") (PVar "table")) (EApp (EApp (EApp (EVar "set") (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "row") "brId"))) (EVar "row")) (EVar "table")))
(DTypeSig true "binderOrdinal" (TyFun (TyCon "BinderId") (TyCon "Int")))
(DFunDef false "binderOrdinal" ((PCon "BinderId" PWild (PVar "i"))) (EVar "i"))
(DTypeSig true "runtimeTypeOf" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool"))) (TyFun (TyCon "Mono") (TyCon "RuntimeType"))))
(DFunDef false "runtimeTypeOf" ((PVar "isCell") (PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t")) () (EApp (EApp (EVar "runtimeTypeOf") (EVar "isCell")) (EVar "t"))) (arm (PCon "Unbound" PWild PWild) () (EVar "RTValue"))))
(DFunDef false "runtimeTypeOf" ((PVar "isCell") (PCon "TQual" (PVar "inner") PWild)) (EApp (EApp (EVar "runtimeTypeOf") (EVar "isCell")) (EVar "inner")))
(DFunDef false "runtimeTypeOf" ((PVar "isCell") (PCon "TCon" (PVar "n") (PVar "o"))) (EApp (EApp (EApp (EVar "headRuntimeType") (EVar "isCell")) (EVar "n")) (EVar "o")))
(DFunDef false "runtimeTypeOf" ((PVar "isCell") (PCon "TApp" (PVar "f") PWild)) (EApp (EApp (EVar "appliedRuntimeType") (EVar "isCell")) (EVar "f")))
(DFunDef false "runtimeTypeOf" (PWild PWild) (EVar "RTValue"))
(DTypeSig false "appliedRuntimeType" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool"))) (TyFun (TyCon "Mono") (TyCon "RuntimeType"))))
(DFunDef false "appliedRuntimeType" ((PVar "isCell") (PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t")) () (EApp (EApp (EVar "appliedRuntimeType") (EVar "isCell")) (EVar "t"))) (arm (PCon "Unbound" PWild PWild) () (EVar "RTValue"))))
(DFunDef false "appliedRuntimeType" ((PVar "isCell") (PCon "TQual" (PVar "inner") PWild)) (EApp (EApp (EVar "appliedRuntimeType") (EVar "isCell")) (EVar "inner")))
(DFunDef false "appliedRuntimeType" ((PVar "isCell") (PCon "TApp" (PVar "f") PWild)) (EApp (EApp (EVar "appliedRuntimeType") (EVar "isCell")) (EVar "f")))
(DFunDef false "appliedRuntimeType" ((PVar "isCell") (PCon "TCon" (PVar "n") (PVar "o"))) (EMatch (EApp (EApp (EApp (EVar "headRuntimeType") (EVar "isCell")) (EVar "n")) (EVar "o")) (arm (PCon "RTCon") () (EVar "RTCon")) (arm PWild () (EVar "RTValue"))))
(DFunDef false "appliedRuntimeType" (PWild PWild) (EVar "RTValue"))
(DTypeSig false "headRuntimeType" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool"))) (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "RuntimeType")))))
(DFunDef false "headRuntimeType" (PWild (PVar "n") (PCon "OriginBuiltin")) (EApp (EVar "builtinRuntimeType") (EVar "n")))
(DFunDef false "headRuntimeType" ((PVar "isCell") (PVar "n") (PVar "o")) (EIf (EApp (EApp (EVar "isCell") (EVar "n")) (EVar "o")) (EVar "RTCon") (EVar "RTValue")))
(DTypeSig false "builtinRuntimeType" (TyFun (TyCon "String") (TyCon "RuntimeType")))
(DFunDef false "builtinRuntimeType" ((PLit (LString "Int"))) (EVar "RTInt"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "Float"))) (EVar "RTFloat"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "Bool"))) (EVar "RTBool"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "Char"))) (EVar "RTChar"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "String"))) (EVar "RTString"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "Unit"))) (EVar "RTUnit"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "U64"))) (EVar "RTU64"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "I64"))) (EVar "RTI64"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "U32"))) (EVar "RTU32"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "I32"))) (EVar "RTI32"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "U16"))) (EVar "RTU16"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "U8"))) (EVar "RTU8"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "List"))) (EVar "RTCon"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "__tuple2__"))) (EVar "RTCon"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "__tuple3__"))) (EVar "RTCon"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "__tuple4__"))) (EVar "RTCon"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "__tuple5__"))) (EVar "RTCon"))
(DFunDef false "builtinRuntimeType" (PWild) (EVar "RTValue"))
(DTypeSig true "binderRowIn" (TyFun (TyApp (TyCon "Option") (TyCon "BinderTypeTable")) (TyFun (TyCon "BinderId") (TyApp (TyCon "Option") (TyCon "BinderRow")))))
(DFunDef false "binderRowIn" ((PCon "None") PWild) (EVar "None"))
(DFunDef false "binderRowIn" ((PCon "Some" (PVar "table")) (PCon "BinderId" (PVar "m") (PVar "i"))) (EApp (EApp (EApp (EVar "rowIn") (EVar "table")) (EVar "m")) (EVar "i")))
(DTypeSig false "rowIn" (TyFun (TyCon "BinderTypeTable") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "BinderRow"))))))
(DFunDef false "rowIn" ((PVar "table") (PVar "m") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "table")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "row")) () (EMatch (EFieldAccess (EVar "row") "brId") (arm (PCon "BinderId" (PVar "m2") PWild) () (EIf (EBinOp "==" (EVar "m2") (EVar "m")) (EApp (EVar "Some") (EVar "row")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "binder table: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " answered by module "))) (EApp (EVar "display") (EVar "m2"))) (ELit (LString ""))))))))))
(DTypeSig true "runtimeTypeName" (TyFun (TyCon "RuntimeType") (TyCon "String")))
(DFunDef false "runtimeTypeName" ((PCon "RTInt")) (ELit (LString "RTInt")))
(DFunDef false "runtimeTypeName" ((PCon "RTFloat")) (ELit (LString "RTFloat")))
(DFunDef false "runtimeTypeName" ((PCon "RTBool")) (ELit (LString "RTBool")))
(DFunDef false "runtimeTypeName" ((PCon "RTChar")) (ELit (LString "RTChar")))
(DFunDef false "runtimeTypeName" ((PCon "RTString")) (ELit (LString "RTString")))
(DFunDef false "runtimeTypeName" ((PCon "RTUnit")) (ELit (LString "RTUnit")))
(DFunDef false "runtimeTypeName" ((PCon "RTU64")) (ELit (LString "RTU64")))
(DFunDef false "runtimeTypeName" ((PCon "RTI64")) (ELit (LString "RTI64")))
(DFunDef false "runtimeTypeName" ((PCon "RTU32")) (ELit (LString "RTU32")))
(DFunDef false "runtimeTypeName" ((PCon "RTI32")) (ELit (LString "RTI32")))
(DFunDef false "runtimeTypeName" ((PCon "RTU16")) (ELit (LString "RTU16")))
(DFunDef false "runtimeTypeName" ((PCon "RTU8")) (ELit (LString "RTU8")))
(DFunDef false "runtimeTypeName" ((PCon "RTCon")) (ELit (LString "RTCon")))
(DFunDef false "runtimeTypeName" ((PCon "RTValue")) (ELit (LString "RTValue")))
(DTypeSig true "runtimeTypeFromName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RuntimeType"))))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTInt"))) (EApp (EVar "Some") (EVar "RTInt")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTFloat"))) (EApp (EVar "Some") (EVar "RTFloat")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTBool"))) (EApp (EVar "Some") (EVar "RTBool")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTChar"))) (EApp (EVar "Some") (EVar "RTChar")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTString"))) (EApp (EVar "Some") (EVar "RTString")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTUnit"))) (EApp (EVar "Some") (EVar "RTUnit")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTU64"))) (EApp (EVar "Some") (EVar "RTU64")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTI64"))) (EApp (EVar "Some") (EVar "RTI64")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTU32"))) (EApp (EVar "Some") (EVar "RTU32")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTI32"))) (EApp (EVar "Some") (EVar "RTI32")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTU16"))) (EApp (EVar "Some") (EVar "RTU16")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTU8"))) (EApp (EVar "Some") (EVar "RTU8")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTCon"))) (EApp (EVar "Some") (EVar "RTCon")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTValue"))) (EApp (EVar "Some") (EVar "RTValue")))
(DFunDef false "runtimeTypeFromName" (PWild) (EVar "None"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true))))
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "get" false) (mem "set" false))))
(DData Public "RuntimeType" () ((variant "RTInt" (ConPos)) (variant "RTFloat" (ConPos)) (variant "RTBool" (ConPos)) (variant "RTChar" (ConPos)) (variant "RTString" (ConPos)) (variant "RTUnit" (ConPos)) (variant "RTU64" (ConPos)) (variant "RTI64" (ConPos)) (variant "RTU32" (ConPos)) (variant "RTI32" (ConPos)) (variant "RTU16" (ConPos)) (variant "RTU8" (ConPos)) (variant "RTCon" (ConPos)) (variant "RTValue" (ConPos))) ())
(DImpl true "Eq" ((TyCon "RuntimeType")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RTInt") (PCon "RTInt")) () (EVar "True")) (arm (PTuple (PCon "RTFloat") (PCon "RTFloat")) () (EVar "True")) (arm (PTuple (PCon "RTBool") (PCon "RTBool")) () (EVar "True")) (arm (PTuple (PCon "RTChar") (PCon "RTChar")) () (EVar "True")) (arm (PTuple (PCon "RTString") (PCon "RTString")) () (EVar "True")) (arm (PTuple (PCon "RTUnit") (PCon "RTUnit")) () (EVar "True")) (arm (PTuple (PCon "RTU64") (PCon "RTU64")) () (EVar "True")) (arm (PTuple (PCon "RTI64") (PCon "RTI64")) () (EVar "True")) (arm (PTuple (PCon "RTU32") (PCon "RTU32")) () (EVar "True")) (arm (PTuple (PCon "RTI32") (PCon "RTI32")) () (EVar "True")) (arm (PTuple (PCon "RTU16") (PCon "RTU16")) () (EVar "True")) (arm (PTuple (PCon "RTU8") (PCon "RTU8")) () (EVar "True")) (arm (PTuple (PCon "RTCon") (PCon "RTCon")) () (EVar "True")) (arm (PTuple (PCon "RTValue") (PCon "RTValue")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "RuntimeType")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RTInt") () (ELit (LString "RTInt"))) (arm (PCon "RTFloat") () (ELit (LString "RTFloat"))) (arm (PCon "RTBool") () (ELit (LString "RTBool"))) (arm (PCon "RTChar") () (ELit (LString "RTChar"))) (arm (PCon "RTString") () (ELit (LString "RTString"))) (arm (PCon "RTUnit") () (ELit (LString "RTUnit"))) (arm (PCon "RTU64") () (ELit (LString "RTU64"))) (arm (PCon "RTI64") () (ELit (LString "RTI64"))) (arm (PCon "RTU32") () (ELit (LString "RTU32"))) (arm (PCon "RTI32") () (ELit (LString "RTI32"))) (arm (PCon "RTU16") () (ELit (LString "RTU16"))) (arm (PCon "RTU8") () (ELit (LString "RTU8"))) (arm (PCon "RTCon") () (ELit (LString "RTCon"))) (arm (PCon "RTValue") () (ELit (LString "RTValue")))))))
(DData Public "BinderRow" () ((variant "BinderRow" (ConNamed (field "brId" (TyCon "BinderId")) (field "brName" (TyCon "String")) (field "brType" (TyCon "RuntimeType")) (field "brReturns" (TyApp (TyCon "Option") (TyCon "RuntimeType"))) (field "brSigned" (TyCon "Bool"))))) ())
(DTypeAlias true "BinderTypeTable" () (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "BinderRow")))
(DTypeSig true "emptyBinderTypes" (TyCon "BinderTypeTable"))
(DFunDef false "emptyBinderTypes" () (EVar "Tip"))
(DTypeSig true "addBinderRow" (TyFun (TyCon "BinderRow") (TyFun (TyCon "BinderTypeTable") (TyCon "BinderTypeTable"))))
(DFunDef false "addBinderRow" ((PVar "row") (PVar "table")) (EApp (EApp (EApp (EVar "set") (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "row") "brId"))) (EVar "row")) (EVar "table")))
(DTypeSig true "binderOrdinal" (TyFun (TyCon "BinderId") (TyCon "Int")))
(DFunDef false "binderOrdinal" ((PCon "BinderId" PWild (PVar "i"))) (EVar "i"))
(DTypeSig true "runtimeTypeOf" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool"))) (TyFun (TyCon "Mono") (TyCon "RuntimeType"))))
(DFunDef false "runtimeTypeOf" ((PVar "isCell") (PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t")) () (EApp (EApp (EVar "runtimeTypeOf") (EVar "isCell")) (EVar "t"))) (arm (PCon "Unbound" PWild PWild) () (EVar "RTValue"))))
(DFunDef false "runtimeTypeOf" ((PVar "isCell") (PCon "TQual" (PVar "inner") PWild)) (EApp (EApp (EVar "runtimeTypeOf") (EVar "isCell")) (EVar "inner")))
(DFunDef false "runtimeTypeOf" ((PVar "isCell") (PCon "TCon" (PVar "n") (PVar "o"))) (EApp (EApp (EApp (EVar "headRuntimeType") (EVar "isCell")) (EVar "n")) (EVar "o")))
(DFunDef false "runtimeTypeOf" ((PVar "isCell") (PCon "TApp" (PVar "f") PWild)) (EApp (EApp (EVar "appliedRuntimeType") (EVar "isCell")) (EVar "f")))
(DFunDef false "runtimeTypeOf" (PWild PWild) (EVar "RTValue"))
(DTypeSig false "appliedRuntimeType" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool"))) (TyFun (TyCon "Mono") (TyCon "RuntimeType"))))
(DFunDef false "appliedRuntimeType" ((PVar "isCell") (PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t")) () (EApp (EApp (EVar "appliedRuntimeType") (EVar "isCell")) (EVar "t"))) (arm (PCon "Unbound" PWild PWild) () (EVar "RTValue"))))
(DFunDef false "appliedRuntimeType" ((PVar "isCell") (PCon "TQual" (PVar "inner") PWild)) (EApp (EApp (EVar "appliedRuntimeType") (EVar "isCell")) (EVar "inner")))
(DFunDef false "appliedRuntimeType" ((PVar "isCell") (PCon "TApp" (PVar "f") PWild)) (EApp (EApp (EVar "appliedRuntimeType") (EVar "isCell")) (EVar "f")))
(DFunDef false "appliedRuntimeType" ((PVar "isCell") (PCon "TCon" (PVar "n") (PVar "o"))) (EMatch (EApp (EApp (EApp (EVar "headRuntimeType") (EVar "isCell")) (EVar "n")) (EVar "o")) (arm (PCon "RTCon") () (EVar "RTCon")) (arm PWild () (EVar "RTValue"))))
(DFunDef false "appliedRuntimeType" (PWild PWild) (EVar "RTValue"))
(DTypeSig false "headRuntimeType" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool"))) (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "RuntimeType")))))
(DFunDef false "headRuntimeType" (PWild (PVar "n") (PCon "OriginBuiltin")) (EApp (EVar "builtinRuntimeType") (EVar "n")))
(DFunDef false "headRuntimeType" ((PVar "isCell") (PVar "n") (PVar "o")) (EIf (EApp (EApp (EVar "isCell") (EVar "n")) (EVar "o")) (EVar "RTCon") (EVar "RTValue")))
(DTypeSig false "builtinRuntimeType" (TyFun (TyCon "String") (TyCon "RuntimeType")))
(DFunDef false "builtinRuntimeType" ((PLit (LString "Int"))) (EVar "RTInt"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "Float"))) (EVar "RTFloat"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "Bool"))) (EVar "RTBool"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "Char"))) (EVar "RTChar"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "String"))) (EVar "RTString"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "Unit"))) (EVar "RTUnit"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "U64"))) (EVar "RTU64"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "I64"))) (EVar "RTI64"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "U32"))) (EVar "RTU32"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "I32"))) (EVar "RTI32"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "U16"))) (EVar "RTU16"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "U8"))) (EVar "RTU8"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "List"))) (EVar "RTCon"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "__tuple2__"))) (EVar "RTCon"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "__tuple3__"))) (EVar "RTCon"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "__tuple4__"))) (EVar "RTCon"))
(DFunDef false "builtinRuntimeType" ((PLit (LString "__tuple5__"))) (EVar "RTCon"))
(DFunDef false "builtinRuntimeType" (PWild) (EVar "RTValue"))
(DTypeSig true "binderRowIn" (TyFun (TyApp (TyCon "Option") (TyCon "BinderTypeTable")) (TyFun (TyCon "BinderId") (TyApp (TyCon "Option") (TyCon "BinderRow")))))
(DFunDef false "binderRowIn" ((PCon "None") PWild) (EVar "None"))
(DFunDef false "binderRowIn" ((PCon "Some" (PVar "table")) (PCon "BinderId" (PVar "m") (PVar "i"))) (EApp (EApp (EApp (EVar "rowIn") (EVar "table")) (EVar "m")) (EVar "i")))
(DTypeSig false "rowIn" (TyFun (TyCon "BinderTypeTable") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "BinderRow"))))))
(DFunDef false "rowIn" ((PVar "table") (PVar "m") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "table")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "row")) () (EMatch (EFieldAccess (EVar "row") "brId") (arm (PCon "BinderId" (PVar "m2") PWild) () (EIf (EBinOp "==" (EVar "m2") (EVar "m")) (EApp (EVar "Some") (EVar "row")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "binder table: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " answered by module "))) (EApp (EMethodRef "display") (EVar "m2"))) (ELit (LString ""))))))))))
(DTypeSig true "runtimeTypeName" (TyFun (TyCon "RuntimeType") (TyCon "String")))
(DFunDef false "runtimeTypeName" ((PCon "RTInt")) (ELit (LString "RTInt")))
(DFunDef false "runtimeTypeName" ((PCon "RTFloat")) (ELit (LString "RTFloat")))
(DFunDef false "runtimeTypeName" ((PCon "RTBool")) (ELit (LString "RTBool")))
(DFunDef false "runtimeTypeName" ((PCon "RTChar")) (ELit (LString "RTChar")))
(DFunDef false "runtimeTypeName" ((PCon "RTString")) (ELit (LString "RTString")))
(DFunDef false "runtimeTypeName" ((PCon "RTUnit")) (ELit (LString "RTUnit")))
(DFunDef false "runtimeTypeName" ((PCon "RTU64")) (ELit (LString "RTU64")))
(DFunDef false "runtimeTypeName" ((PCon "RTI64")) (ELit (LString "RTI64")))
(DFunDef false "runtimeTypeName" ((PCon "RTU32")) (ELit (LString "RTU32")))
(DFunDef false "runtimeTypeName" ((PCon "RTI32")) (ELit (LString "RTI32")))
(DFunDef false "runtimeTypeName" ((PCon "RTU16")) (ELit (LString "RTU16")))
(DFunDef false "runtimeTypeName" ((PCon "RTU8")) (ELit (LString "RTU8")))
(DFunDef false "runtimeTypeName" ((PCon "RTCon")) (ELit (LString "RTCon")))
(DFunDef false "runtimeTypeName" ((PCon "RTValue")) (ELit (LString "RTValue")))
(DTypeSig true "runtimeTypeFromName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RuntimeType"))))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTInt"))) (EApp (EVar "Some") (EVar "RTInt")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTFloat"))) (EApp (EVar "Some") (EVar "RTFloat")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTBool"))) (EApp (EVar "Some") (EVar "RTBool")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTChar"))) (EApp (EVar "Some") (EVar "RTChar")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTString"))) (EApp (EVar "Some") (EVar "RTString")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTUnit"))) (EApp (EVar "Some") (EVar "RTUnit")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTU64"))) (EApp (EVar "Some") (EVar "RTU64")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTI64"))) (EApp (EVar "Some") (EVar "RTI64")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTU32"))) (EApp (EVar "Some") (EVar "RTU32")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTI32"))) (EApp (EVar "Some") (EVar "RTI32")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTU16"))) (EApp (EVar "Some") (EVar "RTU16")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTU8"))) (EApp (EVar "Some") (EVar "RTU8")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTCon"))) (EApp (EVar "Some") (EVar "RTCon")))
(DFunDef false "runtimeTypeFromName" ((PLit (LString "RTValue"))) (EApp (EVar "Some") (EVar "RTValue")))
(DFunDef false "runtimeTypeFromName" (PWild) (EVar "None"))
