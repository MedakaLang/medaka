# META
source_lines=166
stages=DESUGAR,MARK
# SOURCE
-- compiler/types/dispatch_keys.mdk — the pure projections of a declaration list
-- that typeclass dispatch is keyed on: an impl's head tag, an interface method's
-- dispatch positions, a constructor's type, and how many type variables an impl head
-- leaves open.
--
-- Everything here is a function of the declarations alone.  The interpreter
-- (`eval/eval.mdk`) and the Core IR lowering (`ir/core_ir_lower.mdk`) both read these
-- projections, so they live below both: the lowering must not import the interpreter,
-- and the interpreter's installed tables (`installDispatchTables`) stay in `eval`.
--
-- The dict-word mint itself is `types/route_key.mdk`; this module only projects
-- declarations onto the words it mints.

import frontend.ast.{
  Ty(..),
  Decl(..),
  IfaceMethod(..),
  variantName,
  ifaceIdentity,
}
import types.route_key.{typeTagOf, funHeadTag}
import support.util.{contains, listLen, anyList}

-- ── head tags ───────────────────────────────────────────────────────────────
-- An arity-distinguished tuple tag (`__tuple2__`, `__tuple3__`, …): each tuple
-- arity gets its own impl group and runtime dispatch tag.  Distinct from
-- `core_ir_lower`'s match-pattern `tupleName = "__tuple__"`, which stays arity-erased
-- because a match column is arity-homogeneous.  `types/repr.mdk` mints the same word
-- as `tupleHeadTagTc`; the two are mirrored, not shared.
export
tupleHeadTag : Int -> String
tupleHeadTag n = "__tuple" ++ intToString n ++ "__"

-- The head tag an impl is filed under.  The caller side stamps the same tag in
-- `tc_mono.headTyconTy` (it peels `TyApp`, `TyEffect` and `TyConstrained` through
-- `headTyNode` and answers the `TyTuple` and `TyFun` heads itself); an arm missing
-- here files the impl under `__none__` while its callers look it up under the real
-- tag (#1617).  `funHeadTag` is imported rather than respelled so the two sides
-- cannot drift.
headTycon : Ty -> Option String
headTycon (TyCon { tyConName = n, tyConOrigin = o }) = Some (typeTagOf o n)
headTycon (TyApp a _) = headTycon a
headTycon (TyConstrained _ t) = headTycon t
headTycon (TyEffect _ _ t) = headTycon t
headTycon (TyQual t _ _) = headTycon t
headTycon (TyTuple ts) = Some (tupleHeadTag (listLen ts))
headTycon (TyFun _ _) = Some funHeadTag
headTycon _ = None

export
headTyconHead : List Ty -> Option String
headTyconHead [] = None
headTyconHead (t :: _) = headTycon t

-- ── specificity ─────────────────────────────────────────────────────────────
countTyvars : Ty -> Int
countTyvars (TyVar _) = 1
countTyvars (TyCon { tyConName = _ }) = 0
countTyvars (TyApp a b) = countTyvars a + countTyvars b
countTyvars (TyFun a b) = countTyvars a + countTyvars b
countTyvars (TyTuple ts) = sumInts (map countTyvars ts)
countTyvars (TyEffect _ _ t) = countTyvars t
countTyvars (TyConstrained _ t) = countTyvars t
countTyvars (TyRow _ _ _) = 0
countTyvars (TyAuth _ _) = 0
countTyvars (TyNamed _ t _) = countTyvars t
countTyvars (TyQual t _ _) = countTyvars t

sumInts : List Int -> Int
sumInts [] = 0
sumInts (x :: xs) = x + sumInts xs

export
tyvarsInArgs : List Ty -> Int
tyvarsInArgs ts = sumInts (map countTyvars ts)

-- ── dispatch positions ──────────────────────────────────────────────────────
-- Arg positions of a method type that mention an interface type parameter.
dispatchPositionsOf : Ty -> List String -> List Int
dispatchPositionsOf mty params = filterMentions 0 (argsOfTy mty) params

argsOfTy : Ty -> List Ty
argsOfTy (TyConstrained _ t) = argsOfTy t
argsOfTy (TyEffect _ _ t) = argsOfTy t
argsOfTy (TyFun (TyNamed _ a _) b) = a :: argsOfTy b
argsOfTy (TyFun a b) = a :: argsOfTy b
argsOfTy _ = []

filterMentions : Int -> List Ty -> List String -> List Int
filterMentions _ [] _ = []
filterMentions i (t :: ts) params
  | tyMentions t params = i :: filterMentions (i + 1) ts params
  | otherwise = filterMentions (i + 1) ts params

tyMentions : Ty -> List String -> Bool
tyMentions (TyVar n) params = contains n params
tyMentions (TyCon { tyConName = _ }) _ = False
tyMentions (TyApp a b) params = tyMentions a params || tyMentions b params
tyMentions (TyFun a b) params = tyMentions a params || tyMentions b params
tyMentions (TyTuple ts) params = anyList (t => tyMentions t params) ts
tyMentions (TyEffect _ _ t) params = tyMentions t params
tyMentions (TyConstrained _ t) params = tyMentions t params
tyMentions (TyNamed _ t _) params = tyMentions t params
tyMentions (TyQual t _ _) params = tyMentions t params
-- A bare row atom (#997) has no wrapped type, but a bare tail var (`<e>`, no
-- labels) IS a mention of that name, the way `TyVar` is for an ordinary parameter.
-- Intentional duplicate of core_ir_lower.mdk's tyMentionsParams TyRow clause: the
-- untyped and typed-Core-IR projections diverge by design.
-- lint-disable-next-line rule-duplicate-body
tyMentions (TyRow _ tail _) params = anyList (v => contains v params) tail
tyMentions (TyAuth _ _) _ = False

-- ── the dispatch-position table ─────────────────────────────────────────────
-- One row per interface method: ((interface identity, interface, method), the
-- argument positions that carry the receiver).  The identity is read off
-- `ifaceOrigin`, so two modules' same-named interfaces are two rows.
--
-- The interpreter must not call this directly: its drivers get the table through
-- `eval.installDispatchTables`, which installs it together with the method reqCount
-- tables `applyMethodDicts` reads (#315, #413).  Only the lowering, which reads no
-- installed state, uses it bare.
export
buildIfaceDispatch : List Decl -> List ((String, String, String), List Int)
buildIfaceDispatch prog = flatMap ifaceDispatchEntries prog

ifaceDispatchEntries : Decl -> List ((String, String, String), List Int)
-- An attribute on an `interface` must not delete its dispatch positions (#1037).
ifaceDispatchEntries (DAttrib _ d) = ifaceDispatchEntries d
ifaceDispatchEntries (DInterface { name = ifaceName, ifaceOrigin = o, typarams = typeParams, methods, ... }) =
  map
    (ifaceMethodEntry (ifaceIdentity o ifaceName) ifaceName typeParams)
    methods
ifaceDispatchEntries _ = []

ifaceMethodEntry : String ->
  String ->
  List String ->
  IfaceMethod ->
  ((String, String, String), List Int)
ifaceMethodEntry ifaceId ifaceName typeParams (IfaceMethod mname mty _ _) = (
  (ifaceId, ifaceName, mname),
  dispatchPositionsOf mty (receiverParam typeParams),
)

-- The receiver (dispatch) typaram is the FIRST interface param.  A multi-param
-- interface (`FromEntries c e`) dispatches on `c`; a trailing element param `e` in
-- an argument type (`List e`) must not mark that argument as a dispatch position.
receiverParam : List String -> List String
receiverParam [] = []
receiverParam (p :: _) = [p]

-- ── constructor → type ──────────────────────────────────────────────────────
-- A constructor's type is recorded by its dispatch word (`typeTagOf`), the word its
-- impls are filed under, so two modules' same-spelled types are two runtime types
-- (#1397).
export
buildCtorToType : List Decl -> List (String, String)
buildCtorToType prog = flatMap ctorTypeEntries prog

ctorTypeEntries : Decl -> List (String, String)
ctorTypeEntries (DData { dataName = tyname, dataCtors = variants, dataOrigin = o }) =
  map (v => (variantName v, typeTagOf o tyname)) variants
ctorTypeEntries (DNewtype { newtypeName = tyname, newtypeCtor = con, newtypeOrigin = o }) =
  [(con, typeTagOf o tyname)]
ctorTypeEntries (DAttrib _ d) = ctorTypeEntries d
ctorTypeEntries _ = []
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Decl" true) (mem "IfaceMethod" true) (mem "variantName" false) (mem "ifaceIdentity" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "typeTagOf" false) (mem "funHeadTag" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "anyList" false))))
(DTypeSig true "tupleHeadTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleHeadTag" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tuple")) (EApp (EVar "intToString") (EVar "n"))) (ELit (LString "__"))))
(DTypeSig false "headTycon" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTycon" ((PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false)) (EApp (EVar "Some") (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n"))))
(DFunDef false "headTycon" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "headTycon") (EVar "a")))
(DFunDef false "headTycon" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "headTycon") (EVar "t")))
(DFunDef false "headTycon" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "headTycon") (EVar "t")))
(DFunDef false "headTycon" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "headTycon") (EVar "t")))
(DFunDef false "headTycon" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "Some") (EApp (EVar "tupleHeadTag") (EApp (EVar "listLen") (EVar "ts")))))
(DFunDef false "headTycon" ((PCon "TyFun" PWild PWild)) (EApp (EVar "Some") (EVar "funHeadTag")))
(DFunDef false "headTycon" (PWild) (EVar "None"))
(DTypeSig true "headTyconHead" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTyconHead" ((PList)) (EVar "None"))
(DFunDef false "headTyconHead" ((PCons (PVar "t") PWild)) (EApp (EVar "headTycon") (EVar "t")))
(DTypeSig false "countTyvars" (TyFun (TyCon "Ty") (TyCon "Int")))
(DFunDef false "countTyvars" ((PCon "TyVar" PWild)) (ELit (LInt 1)))
(DFunDef false "countTyvars" ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (ELit (LInt 0)))
(DFunDef false "countTyvars" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "countTyvars") (EVar "a")) (EApp (EVar "countTyvars") (EVar "b"))))
(DFunDef false "countTyvars" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "countTyvars") (EVar "a")) (EApp (EVar "countTyvars") (EVar "b"))))
(DFunDef false "countTyvars" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "sumInts") (EApp (EApp (EVar "map") (EVar "countTyvars")) (EVar "ts"))))
(DFunDef false "countTyvars" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "countTyvars") (EVar "t")))
(DFunDef false "countTyvars" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "countTyvars") (EVar "t")))
(DFunDef false "countTyvars" ((PCon "TyRow" PWild PWild PWild)) (ELit (LInt 0)))
(DFunDef false "countTyvars" ((PCon "TyAuth" PWild PWild)) (ELit (LInt 0)))
(DFunDef false "countTyvars" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "countTyvars") (EVar "t")))
(DFunDef false "countTyvars" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "countTyvars") (EVar "t")))
(DTypeSig false "sumInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "sumInts" ((PList)) (ELit (LInt 0)))
(DFunDef false "sumInts" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "+" (EVar "x") (EApp (EVar "sumInts") (EVar "xs"))))
(DTypeSig true "tyvarsInArgs" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Int")))
(DFunDef false "tyvarsInArgs" ((PVar "ts")) (EApp (EVar "sumInts") (EApp (EApp (EVar "map") (EVar "countTyvars")) (EVar "ts"))))
(DTypeSig false "dispatchPositionsOf" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "dispatchPositionsOf" ((PVar "mty") (PVar "params")) (EApp (EApp (EApp (EVar "filterMentions") (ELit (LInt 0))) (EApp (EVar "argsOfTy") (EVar "mty"))) (EVar "params")))
(DTypeSig false "argsOfTy" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "argsOfTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "argsOfTy") (EVar "t")))
(DFunDef false "argsOfTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "argsOfTy") (EVar "t")))
(DFunDef false "argsOfTy" ((PCon "TyFun" (PCon "TyNamed" PWild (PVar "a") PWild) (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "argsOfTy") (EVar "b"))))
(DFunDef false "argsOfTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "argsOfTy") (EVar "b"))))
(DFunDef false "argsOfTy" (PWild) (EListLit))
(DTypeSig false "filterMentions" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "filterMentions" (PWild (PList) PWild) (EListLit))
(DFunDef false "filterMentions" ((PVar "i") (PCons (PVar "t") (PVar "ts")) (PVar "params")) (EIf (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EVar "filterMentions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "filterMentions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tyMentions" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentions" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params")))
(DFunDef false "tyMentions" ((PRec "TyCon" ((rf "tyConName" PWild)) false) PWild) (EVar "False"))
(DFunDef false "tyMentions" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentions") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentions" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentions") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentions" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentions" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyNamed" PWild (PVar "t") PWild) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyQual" (PVar "t") PWild PWild) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyRow" PWild (PVar "tail") PWild) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "params")))) (EVar "tail")))
(DFunDef false "tyMentions" ((PCon "TyAuth" PWild PWild) PWild) (EVar "False"))
(DTypeSig true "buildIfaceDispatch" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "buildIfaceDispatch" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifaceDispatchEntries")) (EVar "prog")))
(DTypeSig false "ifaceDispatchEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "ifaceDispatchEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceDispatchEntries") (EVar "d")))
(DFunDef false "ifaceDispatchEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "ifaceOrigin" (PVar "o")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "ifaceMethodEntry") (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "ifaceName"))) (EVar "ifaceName")) (EVar "typeParams"))) (EVar "methods")))
(DFunDef false "ifaceDispatchEntries" (PWild) (EListLit))
(DTypeSig false "ifaceMethodEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "ifaceMethodEntry" ((PVar "ifaceId") (PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (ETuple (ETuple (EVar "ifaceId") (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EVar "dispatchPositionsOf") (EVar "mty")) (EApp (EVar "receiverParam") (EVar "typeParams")))))
(DTypeSig false "receiverParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "receiverParam" ((PList)) (EListLit))
(DFunDef false "receiverParam" ((PCons (PVar "p") PWild)) (EListLit (EVar "p")))
(DTypeSig true "buildCtorToType" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "buildCtorToType" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ctorTypeEntries")) (EVar "prog")))
(DTypeSig false "ctorTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "ctorTypeEntries" ((PRec "DData" ((rf "dataName" (PVar "tyname")) (rf "dataCtors" (PVar "variants")) (rf "dataOrigin" (PVar "o"))) false)) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "variantName") (EVar "v")) (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "tyname"))))) (EVar "variants")))
(DFunDef false "ctorTypeEntries" ((PRec "DNewtype" ((rf "newtypeName" (PVar "tyname")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeOrigin" (PVar "o"))) false)) (EListLit (ETuple (EVar "con") (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "tyname")))))
(DFunDef false "ctorTypeEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ctorTypeEntries") (EVar "d")))
(DFunDef false "ctorTypeEntries" (PWild) (EListLit))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Decl" true) (mem "IfaceMethod" true) (mem "variantName" false) (mem "ifaceIdentity" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "typeTagOf" false) (mem "funHeadTag" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "anyList" false))))
(DTypeSig true "tupleHeadTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleHeadTag" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tuple")) (EApp (EVar "intToString") (EVar "n"))) (ELit (LString "__"))))
(DTypeSig false "headTycon" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTycon" ((PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false)) (EApp (EVar "Some") (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n"))))
(DFunDef false "headTycon" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "headTycon") (EVar "a")))
(DFunDef false "headTycon" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "headTycon") (EVar "t")))
(DFunDef false "headTycon" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "headTycon") (EVar "t")))
(DFunDef false "headTycon" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "headTycon") (EVar "t")))
(DFunDef false "headTycon" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "Some") (EApp (EVar "tupleHeadTag") (EApp (EVar "listLen") (EVar "ts")))))
(DFunDef false "headTycon" ((PCon "TyFun" PWild PWild)) (EApp (EVar "Some") (EVar "funHeadTag")))
(DFunDef false "headTycon" (PWild) (EVar "None"))
(DTypeSig true "headTyconHead" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTyconHead" ((PList)) (EVar "None"))
(DFunDef false "headTyconHead" ((PCons (PVar "t") PWild)) (EApp (EVar "headTycon") (EVar "t")))
(DTypeSig false "countTyvars" (TyFun (TyCon "Ty") (TyCon "Int")))
(DFunDef false "countTyvars" ((PCon "TyVar" PWild)) (ELit (LInt 1)))
(DFunDef false "countTyvars" ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (ELit (LInt 0)))
(DFunDef false "countTyvars" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "countTyvars") (EVar "a")) (EApp (EVar "countTyvars") (EVar "b"))))
(DFunDef false "countTyvars" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "countTyvars") (EVar "a")) (EApp (EVar "countTyvars") (EVar "b"))))
(DFunDef false "countTyvars" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "sumInts") (EApp (EApp (EMethodRef "map") (EVar "countTyvars")) (EVar "ts"))))
(DFunDef false "countTyvars" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "countTyvars") (EVar "t")))
(DFunDef false "countTyvars" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "countTyvars") (EVar "t")))
(DFunDef false "countTyvars" ((PCon "TyRow" PWild PWild PWild)) (ELit (LInt 0)))
(DFunDef false "countTyvars" ((PCon "TyAuth" PWild PWild)) (ELit (LInt 0)))
(DFunDef false "countTyvars" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "countTyvars") (EVar "t")))
(DFunDef false "countTyvars" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "countTyvars") (EVar "t")))
(DTypeSig false "sumInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "sumInts" ((PList)) (ELit (LInt 0)))
(DFunDef false "sumInts" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "+" (EVar "x") (EApp (EVar "sumInts") (EVar "xs"))))
(DTypeSig true "tyvarsInArgs" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Int")))
(DFunDef false "tyvarsInArgs" ((PVar "ts")) (EApp (EVar "sumInts") (EApp (EApp (EMethodRef "map") (EVar "countTyvars")) (EVar "ts"))))
(DTypeSig false "dispatchPositionsOf" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "dispatchPositionsOf" ((PVar "mty") (PVar "params")) (EApp (EApp (EApp (EVar "filterMentions") (ELit (LInt 0))) (EApp (EVar "argsOfTy") (EVar "mty"))) (EVar "params")))
(DTypeSig false "argsOfTy" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "argsOfTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "argsOfTy") (EVar "t")))
(DFunDef false "argsOfTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "argsOfTy") (EVar "t")))
(DFunDef false "argsOfTy" ((PCon "TyFun" (PCon "TyNamed" PWild (PVar "a") PWild) (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "argsOfTy") (EVar "b"))))
(DFunDef false "argsOfTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "argsOfTy") (EVar "b"))))
(DFunDef false "argsOfTy" (PWild) (EListLit))
(DTypeSig false "filterMentions" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "filterMentions" (PWild (PList) PWild) (EListLit))
(DFunDef false "filterMentions" ((PVar "i") (PCons (PVar "t") (PVar "ts")) (PVar "params")) (EIf (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EVar "filterMentions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "filterMentions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tyMentions" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentions" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params")))
(DFunDef false "tyMentions" ((PRec "TyCon" ((rf "tyConName" PWild)) false) PWild) (EVar "False"))
(DFunDef false "tyMentions" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentions") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentions" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentions") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentions" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentions" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyNamed" PWild (PVar "t") PWild) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyQual" (PVar "t") PWild PWild) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyRow" PWild (PVar "tail") PWild) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "params")))) (EVar "tail")))
(DFunDef false "tyMentions" ((PCon "TyAuth" PWild PWild) PWild) (EVar "False"))
(DTypeSig true "buildIfaceDispatch" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "buildIfaceDispatch" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceDispatchEntries")) (EVar "prog")))
(DTypeSig false "ifaceDispatchEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "ifaceDispatchEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceDispatchEntries") (EVar "d")))
(DFunDef false "ifaceDispatchEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "ifaceOrigin" (PVar "o")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "ifaceMethodEntry") (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "ifaceName"))) (EVar "ifaceName")) (EVar "typeParams"))) (EVar "methods")))
(DFunDef false "ifaceDispatchEntries" (PWild) (EListLit))
(DTypeSig false "ifaceMethodEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "ifaceMethodEntry" ((PVar "ifaceId") (PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (ETuple (ETuple (EVar "ifaceId") (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EVar "dispatchPositionsOf") (EVar "mty")) (EApp (EVar "receiverParam") (EVar "typeParams")))))
(DTypeSig false "receiverParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "receiverParam" ((PList)) (EListLit))
(DFunDef false "receiverParam" ((PCons (PVar "p") PWild)) (EListLit (EVar "p")))
(DTypeSig true "buildCtorToType" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "buildCtorToType" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ctorTypeEntries")) (EVar "prog")))
(DTypeSig false "ctorTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "ctorTypeEntries" ((PRec "DData" ((rf "dataName" (PVar "tyname")) (rf "dataCtors" (PVar "variants")) (rf "dataOrigin" (PVar "o"))) false)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "variantName") (EVar "v")) (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "tyname"))))) (EVar "variants")))
(DFunDef false "ctorTypeEntries" ((PRec "DNewtype" ((rf "newtypeName" (PVar "tyname")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeOrigin" (PVar "o"))) false)) (EListLit (ETuple (EVar "con") (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "tyname")))))
(DFunDef false "ctorTypeEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ctorTypeEntries") (EVar "d")))
(DFunDef false "ctorTypeEntries" (PWild) (EListLit))
