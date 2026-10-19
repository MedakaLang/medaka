# META
source_lines=299
stages=DESUGAR,MARK
# SOURCE
-- Evidence coverage: does a published evidence table answer every site its
-- program's trees carry, once each, with the shape that site's reader accepts?
-- A pure walk over `Decl`s and an `EvTable`, so `types/publish.mdk` can judge a
-- `CheckedProgram` without importing `types.typecheck`.
--
-- The shape each node's reader accepts (`types/route_key.mdk`):
--   `EMethodAt`                          -> `EvMethod` (`evMethodRoutes`)
--   `EDictAt`                            -> `EvMany`   (`evDictRoutes`)
--   `EBinOp`, `EUnOp`, `EWideLit`        -> `EvOne`    (`evSiteRoute`)
--   `ENumLit`                            -> `EvLit`    (`evSiteLit`)
--   `EFieldAccess`, `ERecordUpdate`      -> `EvHead`   (`evSiteHead`)
-- A node carrying `unminted` is answered by its reader without a lookup, so it
-- needs no entry.  `dictPass` rewrites every literal away, so a dict-passed tree
-- holds no `ENumLit` or `EWideLit`.
import frontend.ast.{
  Decl(..),
  Expr(..),
  Arm(..),
  Guard(..),
  GuardArm(..),
  DoStmt(..),
  InterpPart(..),
  FieldAssign(..),
  Section(..),
  FunClause(..),
  LetBind(..),
  IfaceMethod(..),
  MethodDefault(..),
  ImplMethod(..),
  EvId(..),
  isUnminted,
  EvVal(..),
  EvEntry(..),
  EvTable,
}
import support.util.{reverseL}
import types.route_key.{EvIndex(..)}

-- The five answer kinds a published entry can have.
public export data EvShape =
  | ShapeOne
  | ShapeMany
  | ShapeMethod
  | ShapeLit
  | ShapeHead
  deriving (Eq, Debug)

-- One way a table fails its program.  An id is spelled as its module and its
-- ordinal.  `MissingEntry` is a site no entry answers under its id (none at the
-- ordinal, or one published by another module); `WrongShape` is a site whose
-- entry is of a kind its reader refuses, with the expected kind first;
-- `DuplicateOrdinal` is an ordinal two entries are published under.
public export data EvidenceFault =
  | MissingEntry String Int EvShape
  | WrongShape String Int EvShape EvShape
  | DuplicateOrdinal Int
  deriving (Eq, Debug)

export
evShapeOf : EvVal -> EvShape
evShapeOf (EvOne _) = ShapeOne
evShapeOf (EvMany _) = ShapeMany
evShapeOf (EvMethod _ _ _ _ _) = ShapeMethod
evShapeOf (EvLit _ _) = ShapeLit
evShapeOf (EvHead _) = ShapeHead

-- Every fault of [table] against [trees]: duplicated ordinals first, then each
-- uncovered site in tree order.  With no trees (a drive that returns none) only
-- the ordinals are judged.
export
evidenceFaults : Option (List Decl, List (String, List Decl)) ->
  EvTable ->
  List EvidenceFault
evidenceFaults trees table =
  let lo = minOrdinal table
  let arr = arrayMake (slotCount table lo - lo) None
  let dups = fillIndex lo arr table []
  let idx = EvIndex lo arr
  let sites = match trees
    None => []
    Some (core, mods) => modsFaults idx mods (declsFaults idx core [])
  reverseL dups ++ reverseL sites

minOrdinal : EvTable -> Int
minOrdinal [] = 0
minOrdinal ((EvEntry (EvId _ i) _) :: rest) = minFrom rest i

minFrom : EvTable -> Int -> Int
minFrom [] acc = acc
minFrom ((EvEntry (EvId _ i) _) :: rest) acc = minFrom rest (min i acc)

-- one past the largest ordinal in the table, at least [acc]
slotCount : EvTable -> Int -> Int
slotCount [] acc = acc
slotCount ((EvEntry (EvId _ i) _) :: rest) acc =
  slotCount rest (max (i + 1) acc)

fillIndex : Int ->
  Array (Option EvEntry) ->
  EvTable ->
  List EvidenceFault ->
  List EvidenceFault
fillIndex _ _ [] acc = acc
fillIndex lo arr ((e@(EvEntry (EvId _ i) _)) :: rest) acc =
  match arrayGetUnsafe (i - lo) arr
    None =>
      let _ = arraySetUnsafe (i - lo) (Some e) arr
      fillIndex lo arr rest acc
    Some _ => fillIndex lo arr rest (DuplicateOrdinal i :: acc)

-- The fault of one site, consed onto [acc]; none for a covered or unminted site.
site : EvIndex -> EvId -> EvShape -> List EvidenceFault -> List EvidenceFault
site (EvIndex lo arr) (ev@(EvId m i)) want acc
  | isUnminted ev = acc
  | i < lo || i - lo >= arrayLength arr = MissingEntry m i want :: acc
  | otherwise = match arrayGetUnsafe (i - lo) arr
    None => MissingEntry m i want :: acc
    Some (EvEntry (EvId m2 _) v) =>
      if m2 /= m then
        MissingEntry m i want :: acc
      else
        let got = evShapeOf v
        if got == want then acc else WrongShape m i want got :: acc

modsFaults : EvIndex ->
  List (String, List Decl) ->
  List EvidenceFault ->
  List EvidenceFault
modsFaults _ [] acc = acc
modsFaults idx ((_, ds) :: rest) acc =
  modsFaults idx rest (declsFaults idx ds acc)

declsFaults : EvIndex -> List Decl -> List EvidenceFault -> List EvidenceFault
declsFaults _ [] acc = acc
declsFaults idx (d :: rest) acc = declsFaults idx rest (declFaults idx d acc)

-- Every `Decl` that holds an expression.
declFaults : EvIndex -> Decl -> List EvidenceFault -> List EvidenceFault
declFaults idx (DFunDef _ _ _ e _ _) acc = exprFaults idx e acc
declFaults idx (DInterface { methods = ms }) acc = ifaceMethodsFaults idx ms acc
declFaults idx (DImpl { methods = ms }) acc = implMethodsFaults idx ms acc
declFaults idx (DProp _ _ _ e) acc = exprFaults idx e acc
declFaults idx (DTest _ _ e) acc = exprFaults idx e acc
declFaults idx (DLetGroup _ bs) acc = letBindsFaults idx bs acc
declFaults idx (DAttrib _ d) acc = declFaults idx d acc
declFaults _ _ acc = acc

ifaceMethodsFaults : EvIndex ->
  List IfaceMethod ->
  List EvidenceFault ->
  List EvidenceFault
ifaceMethodsFaults _ [] acc = acc
ifaceMethodsFaults idx ((IfaceMethod _ _ (Some (MethodDefault _ e)) _) :: rest) acc =
  ifaceMethodsFaults idx rest (exprFaults idx e acc)
ifaceMethodsFaults idx ((IfaceMethod _ _ None _) :: rest) acc =
  ifaceMethodsFaults idx rest acc

implMethodsFaults : EvIndex ->
  List ImplMethod ->
  List EvidenceFault ->
  List EvidenceFault
implMethodsFaults _ [] acc = acc
implMethodsFaults idx ((ImplMethod _ _ e) :: rest) acc =
  implMethodsFaults idx rest (exprFaults idx e acc)

letBindsFaults : EvIndex ->
  List LetBind ->
  List EvidenceFault ->
  List EvidenceFault
letBindsFaults _ [] acc = acc
letBindsFaults idx ((LetBind _ clauses _ _) :: rest) acc =
  letBindsFaults idx rest (clausesFaults idx clauses acc)

clausesFaults : EvIndex ->
  List FunClause ->
  List EvidenceFault ->
  List EvidenceFault
clausesFaults _ [] acc = acc
clausesFaults idx ((FunClause _ e) :: rest) acc =
  clausesFaults idx rest (exprFaults idx e acc)

exprsFaults : EvIndex -> List Expr -> List EvidenceFault -> List EvidenceFault
exprsFaults _ [] acc = acc
exprsFaults idx (e :: rest) acc = exprsFaults idx rest (exprFaults idx e acc)

-- Every constructor is listed, leaves included, so a new `Expr` node makes this
-- match non-exhaustive rather than silently unwalked.
exprFaults : EvIndex -> Expr -> List EvidenceFault -> List EvidenceFault
exprFaults _ (ELit _) acc = acc
exprFaults _ (EVar _) acc = acc
exprFaults idx (EApp a b) acc = exprFaults idx b (exprFaults idx a acc)
exprFaults idx (ELam _ b) acc = exprFaults idx b acc
exprFaults idx (ELet _ _ _ e1 e2) acc =
  exprFaults idx e2 (exprFaults idx e1 acc)
exprFaults idx (EMatch e0 arms) acc =
  armsFaults idx arms (exprFaults idx e0 acc)
exprFaults idx (EIf c t el) acc =
  exprFaults idx el (exprFaults idx t (exprFaults idx c acc))
exprFaults idx (EBinOp _ a b ev) acc =
  site idx ev ShapeOne (exprFaults idx b (exprFaults idx a acc))
exprFaults idx (EUnOp _ a ev) acc = site idx ev ShapeOne (exprFaults idx a acc)
exprFaults idx (EInfix _ a b) acc = exprFaults idx b (exprFaults idx a acc)
exprFaults idx (EFieldAccess e0 _ ev) acc =
  site idx ev ShapeHead (exprFaults idx e0 acc)
exprFaults idx (ETuple es) acc = exprsFaults idx es acc
exprFaults idx (EListLit es) acc = exprsFaults idx es acc
exprFaults idx (EArrayLit es) acc = exprsFaults idx es acc
exprFaults idx (ERangeList lo hi _) acc =
  exprFaults idx hi (exprFaults idx lo acc)
exprFaults idx (ERangeArray lo hi _) acc =
  exprFaults idx hi (exprFaults idx lo acc)
exprFaults idx (ESlice e0 lo hi _) acc =
  exprFaults idx hi (exprFaults idx lo (exprFaults idx e0 acc))
exprFaults idx (ELetGroup bs e2) acc =
  exprFaults idx e2 (letBindsFaults idx bs acc)
exprFaults _ (ESection (SecBare _)) acc = acc
exprFaults idx (ESection (SecRight _ e0)) acc = exprFaults idx e0 acc
exprFaults idx (ESection (SecLeft e0 _)) acc = exprFaults idx e0 acc
exprFaults idx (EIndex e0 i) acc = exprFaults idx i (exprFaults idx e0 acc)
exprFaults idx (EAnnot e0 _) acc = exprFaults idx e0 acc
exprFaults idx (EHeadAnnot e0 _) acc = exprFaults idx e0 acc
exprFaults idx (EBlock stmts) acc = stmtsFaults idx stmts acc
exprFaults idx (EDo _ stmts) acc = stmtsFaults idx stmts acc
exprFaults idx (EStringInterp parts) acc = interpFaults idx parts acc
exprFaults idx (EGuards arms) acc = guardArmsFaults idx arms acc
exprFaults idx (ERecordCreate _ fs) acc = fieldsFaults idx fs acc
exprFaults idx (ERecordUpdate e0 fs ev) acc =
  site idx ev ShapeHead (fieldsFaults idx fs (exprFaults idx e0 acc))
exprFaults idx (EVariantUpdate _ e0 fs) acc =
  fieldsFaults idx fs (exprFaults idx e0 acc)
exprFaults idx (EMapLit _ kvs) acc = kvsFaults idx kvs acc
exprFaults idx (ESetLit _ es) acc = exprsFaults idx es acc
exprFaults idx (EAsPat _ e0) acc = exprFaults idx e0 acc
exprFaults _ (EMethodRef _) acc = acc
exprFaults _ (EDictApp _) acc = acc
exprFaults _ (EVarAt _ _) acc = acc
exprFaults _ (EVarId _ _) acc = acc
exprFaults idx (EMethodAt _ _ ev) acc = site idx ev ShapeMethod acc
exprFaults idx (EDictAt _ ev) acc = site idx ev ShapeMany acc
exprFaults idx (ELoc _ e0) acc = exprFaults idx e0 acc
exprFaults idx (EDoOrigin _ e0) acc = exprFaults idx e0 acc
exprFaults idx (ENumLit _ ev _) acc = site idx ev ShapeLit acc
exprFaults idx (EWideLit _ _ ev _) acc = site idx ev ShapeOne acc

armsFaults : EvIndex -> List Arm -> List EvidenceFault -> List EvidenceFault
armsFaults _ [] acc = acc
armsFaults idx ((Arm _ gs body) :: rest) acc =
  armsFaults idx rest (exprFaults idx body (guardsFaults idx gs acc))

guardsFaults : EvIndex -> List Guard -> List EvidenceFault -> List EvidenceFault
guardsFaults _ [] acc = acc
guardsFaults idx ((GBool e) :: rest) acc =
  guardsFaults idx rest (exprFaults idx e acc)
guardsFaults idx ((GBind _ e) :: rest) acc =
  guardsFaults idx rest (exprFaults idx e acc)

guardArmsFaults : EvIndex ->
  List GuardArm ->
  List EvidenceFault ->
  List EvidenceFault
guardArmsFaults _ [] acc = acc
guardArmsFaults idx ((GuardArm gs body) :: rest) acc =
  guardArmsFaults idx rest (exprFaults idx body (guardsFaults idx gs acc))

stmtsFaults : EvIndex -> List DoStmt -> List EvidenceFault -> List EvidenceFault
stmtsFaults _ [] acc = acc
stmtsFaults idx (s :: rest) acc = stmtsFaults idx rest (stmtFaults idx s acc)

stmtFaults : EvIndex -> DoStmt -> List EvidenceFault -> List EvidenceFault
stmtFaults idx (DoExpr e) acc = exprFaults idx e acc
stmtFaults idx (DoBind _ e) acc = exprFaults idx e acc
stmtFaults idx (DoLet _ _ _ e _) acc = exprFaults idx e acc
stmtFaults idx (DoAssign _ e) acc = exprFaults idx e acc
stmtFaults idx (DoFieldAssign _ _ e) acc = exprFaults idx e acc

interpFaults : EvIndex ->
  List InterpPart ->
  List EvidenceFault ->
  List EvidenceFault
interpFaults _ [] acc = acc
interpFaults idx ((InterpStr _) :: rest) acc = interpFaults idx rest acc
interpFaults idx ((InterpExpr e) :: rest) acc =
  interpFaults idx rest (exprFaults idx e acc)

fieldsFaults : EvIndex ->
  List FieldAssign ->
  List EvidenceFault ->
  List EvidenceFault
fieldsFaults _ [] acc = acc
fieldsFaults idx ((FieldAssign _ e) :: rest) acc =
  fieldsFaults idx rest (exprFaults idx e acc)

kvsFaults : EvIndex ->
  List (Expr, Expr) ->
  List EvidenceFault ->
  List EvidenceFault
kvsFaults _ [] acc = acc
kvsFaults idx ((k, v) :: rest) acc =
  kvsFaults idx rest (exprFaults idx v (exprFaults idx k acc))
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Arm" true) (mem "Guard" true) (mem "GuardArm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "EvId" true) (mem "isUnminted" false) (mem "EvVal" true) (mem "EvEntry" true) (mem "EvTable" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" true))))
(DData Public "EvShape" () ((variant "ShapeOne" (ConPos)) (variant "ShapeMany" (ConPos)) (variant "ShapeMethod" (ConPos)) (variant "ShapeLit" (ConPos)) (variant "ShapeHead" (ConPos))) ())
(DImpl true "Eq" ((TyCon "EvShape")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ShapeOne") (PCon "ShapeOne")) () (EVar "True")) (arm (PTuple (PCon "ShapeMany") (PCon "ShapeMany")) () (EVar "True")) (arm (PTuple (PCon "ShapeMethod") (PCon "ShapeMethod")) () (EVar "True")) (arm (PTuple (PCon "ShapeLit") (PCon "ShapeLit")) () (EVar "True")) (arm (PTuple (PCon "ShapeHead") (PCon "ShapeHead")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "EvShape")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ShapeOne") () (ELit (LString "ShapeOne"))) (arm (PCon "ShapeMany") () (ELit (LString "ShapeMany"))) (arm (PCon "ShapeMethod") () (ELit (LString "ShapeMethod"))) (arm (PCon "ShapeLit") () (ELit (LString "ShapeLit"))) (arm (PCon "ShapeHead") () (ELit (LString "ShapeHead")))))))
(DData Public "EvidenceFault" () ((variant "MissingEntry" (ConPos (TyCon "String") (TyCon "Int") (TyCon "EvShape"))) (variant "WrongShape" (ConPos (TyCon "String") (TyCon "Int") (TyCon "EvShape") (TyCon "EvShape"))) (variant "DuplicateOrdinal" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "EvidenceFault")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "MissingEntry" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "MissingEntry" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "WrongShape" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "WrongShape" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3")))) (arm (PTuple (PCon "DuplicateOrdinal" (PVar "__a0")) (PCon "DuplicateOrdinal" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "EvidenceFault")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "MissingEntry" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MissingEntry ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2"))))) (arm (PCon "WrongShape" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "WrongShape ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3"))))) (arm (PCon "DuplicateOrdinal" (PVar "__a0")) () (EBinOp "++" (ELit (LString "DuplicateOrdinal ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DTypeSig true "evShapeOf" (TyFun (TyCon "EvVal") (TyCon "EvShape")))
(DFunDef false "evShapeOf" ((PCon "EvOne" PWild)) (EVar "ShapeOne"))
(DFunDef false "evShapeOf" ((PCon "EvMany" PWild)) (EVar "ShapeMany"))
(DFunDef false "evShapeOf" ((PCon "EvMethod" PWild PWild PWild PWild PWild)) (EVar "ShapeMethod"))
(DFunDef false "evShapeOf" ((PCon "EvLit" PWild PWild)) (EVar "ShapeLit"))
(DFunDef false "evShapeOf" ((PCon "EvHead" PWild)) (EVar "ShapeHead"))
(DTypeSig true "evidenceFaults" (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyFun (TyCon "EvTable") (TyApp (TyCon "List") (TyCon "EvidenceFault")))))
(DFunDef false "evidenceFaults" ((PVar "trees") (PVar "table")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "minOrdinal") (EVar "table"))) (DoLet false false (PVar "arr") (EApp (EApp (EVar "arrayMake") (EBinOp "-" (EApp (EApp (EVar "slotCount") (EVar "table")) (EVar "lo")) (EVar "lo"))) (EVar "None"))) (DoLet false false (PVar "dups") (EApp (EApp (EApp (EApp (EVar "fillIndex") (EVar "lo")) (EVar "arr")) (EVar "table")) (EListLit))) (DoLet false false (PVar "idx") (EApp (EApp (EVar "EvIndex") (EVar "lo")) (EVar "arr"))) (DoLet false false (PVar "sites") (EMatch (EVar "trees") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "core") (PVar "mods"))) () (EApp (EApp (EApp (EVar "modsFaults") (EVar "idx")) (EVar "mods")) (EApp (EApp (EApp (EVar "declsFaults") (EVar "idx")) (EVar "core")) (EListLit)))))) (DoExpr (EBinOp "++" (EApp (EVar "reverseL") (EVar "dups")) (EApp (EVar "reverseL") (EVar "sites"))))))
(DTypeSig false "minOrdinal" (TyFun (TyCon "EvTable") (TyCon "Int")))
(DFunDef false "minOrdinal" ((PList)) (ELit (LInt 0)))
(DFunDef false "minOrdinal" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest"))) (EApp (EApp (EVar "minFrom") (EVar "rest")) (EVar "i")))
(DTypeSig false "minFrom" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "minFrom" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "minFrom" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "minFrom") (EVar "rest")) (EApp (EApp (EVar "min") (EVar "i")) (EVar "acc"))))
(DTypeSig false "slotCount" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "slotCount" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "slotCount" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "slotCount") (EVar "rest")) (EApp (EApp (EVar "max") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))))
(DTypeSig false "fillIndex" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "EvTable") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault")))))))
(DFunDef false "fillIndex" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fillIndex" ((PVar "lo") (PVar "arr") (PCons (PAs "e" (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild)) (PVar "rest")) (PVar "acc")) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EVar "arr")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EApp (EVar "Some") (EVar "e"))) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "fillIndex") (EVar "lo")) (EVar "arr")) (EVar "rest")) (EVar "acc"))))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "fillIndex") (EVar "lo")) (EVar "arr")) (EVar "rest")) (EBinOp "::" (EApp (EVar "DuplicateOrdinal") (EVar "i")) (EVar "acc"))))))
(DTypeSig false "site" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyFun (TyCon "EvShape") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault")))))))
(DFunDef false "site" ((PCon "EvIndex" (PVar "lo") (PVar "arr")) (PAs "ev" (PCon "EvId" (PVar "m") (PVar "i"))) (PVar "want") (PVar "acc")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EVar "acc") (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (EVar "lo")) (EBinOp ">=" (EBinOp "-" (EVar "i") (EVar "lo")) (EApp (EVar "arrayLength") (EVar "arr")))) (EBinOp "::" (EApp (EApp (EApp (EVar "MissingEntry") (EVar "m")) (EVar "i")) (EVar "want")) (EVar "acc")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EVar "arr")) (arm (PCon "None") () (EBinOp "::" (EApp (EApp (EApp (EVar "MissingEntry") (EVar "m")) (EVar "i")) (EVar "want")) (EVar "acc"))) (arm (PCon "Some" (PCon "EvEntry" (PCon "EvId" (PVar "m2") PWild) (PVar "v"))) () (EIf (EBinOp "/=" (EVar "m2") (EVar "m")) (EBinOp "::" (EApp (EApp (EApp (EVar "MissingEntry") (EVar "m")) (EVar "i")) (EVar "want")) (EVar "acc")) (EBlock (DoLet false false (PVar "got") (EApp (EVar "evShapeOf") (EVar "v"))) (DoExpr (EIf (EBinOp "==" (EVar "got") (EVar "want")) (EVar "acc") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "WrongShape") (EVar "m")) (EVar "i")) (EVar "want")) (EVar "got")) (EVar "acc")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "modsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "modsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "modsFaults" ((PVar "idx") (PCons (PTuple PWild (PVar "ds")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "modsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "declsFaults") (EVar "idx")) (EVar "ds")) (EVar "acc"))))
(DTypeSig false "declsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "declsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declsFaults" ((PVar "idx") (PCons (PVar "d") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "declFaults") (EVar "idx")) (EVar "d")) (EVar "acc"))))
(DTypeSig false "declFaults" (TyFun (TyCon "EvIndex") (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "declFaults" ((PVar "idx") (PCon "DFunDef" PWild PWild PWild (PVar "e") PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PRec "DInterface" ((rf "methods" (PVar "ms"))) false) (PVar "acc")) (EApp (EApp (EApp (EVar "ifaceMethodsFaults") (EVar "idx")) (EVar "ms")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PRec "DImpl" ((rf "methods" (PVar "ms"))) false) (PVar "acc")) (EApp (EApp (EApp (EVar "implMethodsFaults") (EVar "idx")) (EVar "ms")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PCon "DProp" PWild PWild PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PCon "DTest" PWild PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PCon "DLetGroup" PWild (PVar "bs")) (PVar "acc")) (EApp (EApp (EApp (EVar "letBindsFaults") (EVar "idx")) (EVar "bs")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PCon "DAttrib" PWild (PVar "d")) (PVar "acc")) (EApp (EApp (EApp (EVar "declFaults") (EVar "idx")) (EVar "d")) (EVar "acc")))
(DFunDef false "declFaults" (PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "ifaceMethodsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "ifaceMethodsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "ifaceMethodsFaults" ((PVar "idx") (PCons (PCon "IfaceMethod" PWild PWild (PCon "Some" (PCon "MethodDefault" PWild (PVar "e"))) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "ifaceMethodsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DFunDef false "ifaceMethodsFaults" ((PVar "idx") (PCons (PCon "IfaceMethod" PWild PWild (PCon "None") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "ifaceMethodsFaults") (EVar "idx")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "implMethodsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "implMethodsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "implMethodsFaults" ((PVar "idx") (PCons (PCon "ImplMethod" PWild PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "implMethodsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "letBindsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "letBindsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "letBindsFaults" ((PVar "idx") (PCons (PCon "LetBind" PWild (PVar "clauses") PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "letBindsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "clausesFaults") (EVar "idx")) (EVar "clauses")) (EVar "acc"))))
(DTypeSig false "clausesFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "clausesFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "clausesFaults" ((PVar "idx") (PCons (PCon "FunClause" PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "clausesFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "exprsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "exprsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprsFaults" ((PVar "idx") (PCons (PVar "e") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "exprFaults" (TyFun (TyCon "EvIndex") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "exprFaults" (PWild (PCon "ELit" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" (PWild (PCon "EVar" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EApp" (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "b")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "a")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ELam" PWild (PVar "b")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "b")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e2")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e1")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EMatch" (PVar "e0") (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EVar "armsFaults") (EVar "idx")) (EVar "arms")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "el")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "t")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "c")) (EVar "acc")))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EBinOp" PWild (PVar "a") (PVar "b") (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeOne")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "b")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "a")) (EVar "acc")))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EUnOp" PWild (PVar "a") (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeOne")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "a")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EInfix" PWild (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "b")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "a")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EFieldAccess" (PVar "e0") PWild (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeHead")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ETuple" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprsFaults") (EVar "idx")) (EVar "es")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EListLit" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprsFaults") (EVar "idx")) (EVar "es")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EArrayLit" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprsFaults") (EVar "idx")) (EVar "es")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ERangeList" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "hi")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "lo")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "hi")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "lo")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "hi")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "lo")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ELetGroup" (PVar "bs") (PVar "e2")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e2")) (EApp (EApp (EApp (EVar "letBindsFaults") (EVar "idx")) (EVar "bs")) (EVar "acc"))))
(DFunDef false "exprFaults" (PWild (PCon "ESection" (PCon "SecBare" PWild)) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ESection" (PCon "SecRight" PWild (PVar "e0"))) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ESection" (PCon "SecLeft" (PVar "e0") PWild)) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EIndex" (PVar "e0") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "i")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EAnnot" (PVar "e0") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EHeadAnnot" (PVar "e0") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EBlock" (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EVar "stmtsFaults") (EVar "idx")) (EVar "stmts")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EDo" PWild (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EVar "stmtsFaults") (EVar "idx")) (EVar "stmts")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EStringInterp" (PVar "parts")) (PVar "acc")) (EApp (EApp (EApp (EVar "interpFaults") (EVar "idx")) (EVar "parts")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EGuards" (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardArmsFaults") (EVar "idx")) (EVar "arms")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ERecordCreate" PWild (PVar "fs")) (PVar "acc")) (EApp (EApp (EApp (EVar "fieldsFaults") (EVar "idx")) (EVar "fs")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeHead")) (EApp (EApp (EApp (EVar "fieldsFaults") (EVar "idx")) (EVar "fs")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs")) (PVar "acc")) (EApp (EApp (EApp (EVar "fieldsFaults") (EVar "idx")) (EVar "fs")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EMapLit" PWild (PVar "kvs")) (PVar "acc")) (EApp (EApp (EApp (EVar "kvsFaults") (EVar "idx")) (EVar "kvs")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ESetLit" PWild (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprsFaults") (EVar "idx")) (EVar "es")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EAsPat" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" (PWild (PCon "EMethodRef" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" (PWild (PCon "EDictApp" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" (PWild (PCon "EVarAt" PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" (PWild (PCon "EVarId" PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EMethodAt" PWild PWild (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeMethod")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EDictAt" PWild (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeMany")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ELoc" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EDoOrigin" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ENumLit" PWild (PVar "ev") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeLit")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EWideLit" PWild PWild (PVar "ev") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeOne")) (EVar "acc")))
(DTypeSig false "armsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "armsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "armsFaults" ((PVar "idx") (PCons (PCon "Arm" PWild (PVar "gs") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "armsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "body")) (EApp (EApp (EApp (EVar "guardsFaults") (EVar "idx")) (EVar "gs")) (EVar "acc")))))
(DTypeSig false "guardsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "guardsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "guardsFaults" ((PVar "idx") (PCons (PCon "GBool" (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DFunDef false "guardsFaults" ((PVar "idx") (PCons (PCon "GBind" PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "guardArmsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "guardArmsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "guardArmsFaults" ((PVar "idx") (PCons (PCon "GuardArm" (PVar "gs") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardArmsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "body")) (EApp (EApp (EApp (EVar "guardsFaults") (EVar "idx")) (EVar "gs")) (EVar "acc")))))
(DTypeSig false "stmtsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "stmtsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "stmtsFaults" ((PVar "idx") (PCons (PVar "s") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "stmtsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "stmtFaults") (EVar "idx")) (EVar "s")) (EVar "acc"))))
(DTypeSig false "stmtFaults" (TyFun (TyCon "EvIndex") (TyFun (TyCon "DoStmt") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "stmtFaults" ((PVar "idx") (PCon "DoExpr" (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "stmtFaults" ((PVar "idx") (PCon "DoBind" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "stmtFaults" ((PVar "idx") (PCon "DoLet" PWild PWild PWild (PVar "e") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "stmtFaults" ((PVar "idx") (PCon "DoAssign" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "stmtFaults" ((PVar "idx") (PCon "DoFieldAssign" PWild PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DTypeSig false "interpFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "interpFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "interpFaults" ((PVar "idx") (PCons (PCon "InterpStr" PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "interpFaults") (EVar "idx")) (EVar "rest")) (EVar "acc")))
(DFunDef false "interpFaults" ((PVar "idx") (PCons (PCon "InterpExpr" (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "interpFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "fieldsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "fieldsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fieldsFaults" ((PVar "idx") (PCons (PCon "FieldAssign" PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "fieldsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "kvsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "kvsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "kvsFaults" ((PVar "idx") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "kvsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "v")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "k")) (EVar "acc")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Arm" true) (mem "Guard" true) (mem "GuardArm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "EvId" true) (mem "isUnminted" false) (mem "EvVal" true) (mem "EvEntry" true) (mem "EvTable" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" true))))
(DData Public "EvShape" () ((variant "ShapeOne" (ConPos)) (variant "ShapeMany" (ConPos)) (variant "ShapeMethod" (ConPos)) (variant "ShapeLit" (ConPos)) (variant "ShapeHead" (ConPos))) ())
(DImpl true "Eq" ((TyCon "EvShape")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ShapeOne") (PCon "ShapeOne")) () (EVar "True")) (arm (PTuple (PCon "ShapeMany") (PCon "ShapeMany")) () (EVar "True")) (arm (PTuple (PCon "ShapeMethod") (PCon "ShapeMethod")) () (EVar "True")) (arm (PTuple (PCon "ShapeLit") (PCon "ShapeLit")) () (EVar "True")) (arm (PTuple (PCon "ShapeHead") (PCon "ShapeHead")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "EvShape")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ShapeOne") () (ELit (LString "ShapeOne"))) (arm (PCon "ShapeMany") () (ELit (LString "ShapeMany"))) (arm (PCon "ShapeMethod") () (ELit (LString "ShapeMethod"))) (arm (PCon "ShapeLit") () (ELit (LString "ShapeLit"))) (arm (PCon "ShapeHead") () (ELit (LString "ShapeHead")))))))
(DData Public "EvidenceFault" () ((variant "MissingEntry" (ConPos (TyCon "String") (TyCon "Int") (TyCon "EvShape"))) (variant "WrongShape" (ConPos (TyCon "String") (TyCon "Int") (TyCon "EvShape") (TyCon "EvShape"))) (variant "DuplicateOrdinal" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "EvidenceFault")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "MissingEntry" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "MissingEntry" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "WrongShape" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "WrongShape" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3")))) (arm (PTuple (PCon "DuplicateOrdinal" (PVar "__a0")) (PCon "DuplicateOrdinal" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "EvidenceFault")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "MissingEntry" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MissingEntry ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2"))))) (arm (PCon "WrongShape" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "WrongShape ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3"))))) (arm (PCon "DuplicateOrdinal" (PVar "__a0")) () (EBinOp "++" (ELit (LString "DuplicateOrdinal ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DTypeSig true "evShapeOf" (TyFun (TyCon "EvVal") (TyCon "EvShape")))
(DFunDef false "evShapeOf" ((PCon "EvOne" PWild)) (EVar "ShapeOne"))
(DFunDef false "evShapeOf" ((PCon "EvMany" PWild)) (EVar "ShapeMany"))
(DFunDef false "evShapeOf" ((PCon "EvMethod" PWild PWild PWild PWild PWild)) (EVar "ShapeMethod"))
(DFunDef false "evShapeOf" ((PCon "EvLit" PWild PWild)) (EVar "ShapeLit"))
(DFunDef false "evShapeOf" ((PCon "EvHead" PWild)) (EVar "ShapeHead"))
(DTypeSig true "evidenceFaults" (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyFun (TyCon "EvTable") (TyApp (TyCon "List") (TyCon "EvidenceFault")))))
(DFunDef false "evidenceFaults" ((PVar "trees") (PVar "table")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "minOrdinal") (EVar "table"))) (DoLet false false (PVar "arr") (EApp (EApp (EVar "arrayMake") (EBinOp "-" (EApp (EApp (EVar "slotCount") (EVar "table")) (EVar "lo")) (EVar "lo"))) (EVar "None"))) (DoLet false false (PVar "dups") (EApp (EApp (EApp (EApp (EVar "fillIndex") (EVar "lo")) (EVar "arr")) (EVar "table")) (EListLit))) (DoLet false false (PVar "idx") (EApp (EApp (EVar "EvIndex") (EVar "lo")) (EVar "arr"))) (DoLet false false (PVar "sites") (EMatch (EVar "trees") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "core") (PVar "mods"))) () (EApp (EApp (EApp (EVar "modsFaults") (EVar "idx")) (EVar "mods")) (EApp (EApp (EApp (EVar "declsFaults") (EVar "idx")) (EVar "core")) (EListLit)))))) (DoExpr (EBinOp "++" (EApp (EVar "reverseL") (EVar "dups")) (EApp (EVar "reverseL") (EVar "sites"))))))
(DTypeSig false "minOrdinal" (TyFun (TyCon "EvTable") (TyCon "Int")))
(DFunDef false "minOrdinal" ((PList)) (ELit (LInt 0)))
(DFunDef false "minOrdinal" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest"))) (EApp (EApp (EVar "minFrom") (EVar "rest")) (EVar "i")))
(DTypeSig false "minFrom" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "minFrom" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "minFrom" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "minFrom") (EVar "rest")) (EApp (EApp (EMethodRef "min") (EVar "i")) (EVar "acc"))))
(DTypeSig false "slotCount" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "slotCount" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "slotCount" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "slotCount") (EVar "rest")) (EApp (EApp (EMethodRef "max") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))))
(DTypeSig false "fillIndex" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "EvTable") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault")))))))
(DFunDef false "fillIndex" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fillIndex" ((PVar "lo") (PVar "arr") (PCons (PAs "e" (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild)) (PVar "rest")) (PVar "acc")) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EVar "arr")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EApp (EVar "Some") (EVar "e"))) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "fillIndex") (EVar "lo")) (EVar "arr")) (EVar "rest")) (EVar "acc"))))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "fillIndex") (EVar "lo")) (EVar "arr")) (EVar "rest")) (EBinOp "::" (EApp (EVar "DuplicateOrdinal") (EVar "i")) (EVar "acc"))))))
(DTypeSig false "site" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyFun (TyCon "EvShape") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault")))))))
(DFunDef false "site" ((PCon "EvIndex" (PVar "lo") (PVar "arr")) (PAs "ev" (PCon "EvId" (PVar "m") (PVar "i"))) (PVar "want") (PVar "acc")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EVar "acc") (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (EVar "lo")) (EBinOp ">=" (EBinOp "-" (EVar "i") (EVar "lo")) (EApp (EVar "arrayLength") (EVar "arr")))) (EBinOp "::" (EApp (EApp (EApp (EVar "MissingEntry") (EVar "m")) (EVar "i")) (EVar "want")) (EVar "acc")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EVar "arr")) (arm (PCon "None") () (EBinOp "::" (EApp (EApp (EApp (EVar "MissingEntry") (EVar "m")) (EVar "i")) (EVar "want")) (EVar "acc"))) (arm (PCon "Some" (PCon "EvEntry" (PCon "EvId" (PVar "m2") PWild) (PVar "v"))) () (EIf (EBinOp "/=" (EVar "m2") (EVar "m")) (EBinOp "::" (EApp (EApp (EApp (EVar "MissingEntry") (EVar "m")) (EVar "i")) (EVar "want")) (EVar "acc")) (EBlock (DoLet false false (PVar "got") (EApp (EVar "evShapeOf") (EVar "v"))) (DoExpr (EIf (EBinOp "==" (EVar "got") (EVar "want")) (EVar "acc") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "WrongShape") (EVar "m")) (EVar "i")) (EVar "want")) (EVar "got")) (EVar "acc")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "modsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "modsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "modsFaults" ((PVar "idx") (PCons (PTuple PWild (PVar "ds")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "modsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "declsFaults") (EVar "idx")) (EVar "ds")) (EVar "acc"))))
(DTypeSig false "declsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "declsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declsFaults" ((PVar "idx") (PCons (PVar "d") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "declFaults") (EVar "idx")) (EVar "d")) (EVar "acc"))))
(DTypeSig false "declFaults" (TyFun (TyCon "EvIndex") (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "declFaults" ((PVar "idx") (PCon "DFunDef" PWild PWild PWild (PVar "e") PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PRec "DInterface" ((rf "methods" (PVar "ms"))) false) (PVar "acc")) (EApp (EApp (EApp (EVar "ifaceMethodsFaults") (EVar "idx")) (EVar "ms")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PRec "DImpl" ((rf "methods" (PVar "ms"))) false) (PVar "acc")) (EApp (EApp (EApp (EVar "implMethodsFaults") (EVar "idx")) (EVar "ms")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PCon "DProp" PWild PWild PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PCon "DTest" PWild PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PCon "DLetGroup" PWild (PVar "bs")) (PVar "acc")) (EApp (EApp (EApp (EVar "letBindsFaults") (EVar "idx")) (EVar "bs")) (EVar "acc")))
(DFunDef false "declFaults" ((PVar "idx") (PCon "DAttrib" PWild (PVar "d")) (PVar "acc")) (EApp (EApp (EApp (EVar "declFaults") (EVar "idx")) (EVar "d")) (EVar "acc")))
(DFunDef false "declFaults" (PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "ifaceMethodsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "ifaceMethodsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "ifaceMethodsFaults" ((PVar "idx") (PCons (PCon "IfaceMethod" PWild PWild (PCon "Some" (PCon "MethodDefault" PWild (PVar "e"))) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "ifaceMethodsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DFunDef false "ifaceMethodsFaults" ((PVar "idx") (PCons (PCon "IfaceMethod" PWild PWild (PCon "None") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "ifaceMethodsFaults") (EVar "idx")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "implMethodsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "implMethodsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "implMethodsFaults" ((PVar "idx") (PCons (PCon "ImplMethod" PWild PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "implMethodsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "letBindsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "letBindsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "letBindsFaults" ((PVar "idx") (PCons (PCon "LetBind" PWild (PVar "clauses") PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "letBindsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "clausesFaults") (EVar "idx")) (EVar "clauses")) (EVar "acc"))))
(DTypeSig false "clausesFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "clausesFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "clausesFaults" ((PVar "idx") (PCons (PCon "FunClause" PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "clausesFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "exprsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "exprsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprsFaults" ((PVar "idx") (PCons (PVar "e") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "exprFaults" (TyFun (TyCon "EvIndex") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "exprFaults" (PWild (PCon "ELit" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" (PWild (PCon "EVar" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EApp" (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "b")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "a")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ELam" PWild (PVar "b")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "b")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e2")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e1")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EMatch" (PVar "e0") (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EVar "armsFaults") (EVar "idx")) (EVar "arms")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "el")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "t")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "c")) (EVar "acc")))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EBinOp" PWild (PVar "a") (PVar "b") (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeOne")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "b")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "a")) (EVar "acc")))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EUnOp" PWild (PVar "a") (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeOne")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "a")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EInfix" PWild (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "b")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "a")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EFieldAccess" (PVar "e0") PWild (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeHead")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ETuple" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprsFaults") (EVar "idx")) (EVar "es")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EListLit" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprsFaults") (EVar "idx")) (EVar "es")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EArrayLit" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprsFaults") (EVar "idx")) (EVar "es")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ERangeList" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "hi")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "lo")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "hi")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "lo")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "hi")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "lo")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ELetGroup" (PVar "bs") (PVar "e2")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e2")) (EApp (EApp (EApp (EVar "letBindsFaults") (EVar "idx")) (EVar "bs")) (EVar "acc"))))
(DFunDef false "exprFaults" (PWild (PCon "ESection" (PCon "SecBare" PWild)) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ESection" (PCon "SecRight" PWild (PVar "e0"))) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ESection" (PCon "SecLeft" (PVar "e0") PWild)) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EIndex" (PVar "e0") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "i")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EAnnot" (PVar "e0") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EHeadAnnot" (PVar "e0") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EBlock" (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EVar "stmtsFaults") (EVar "idx")) (EVar "stmts")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EDo" PWild (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EVar "stmtsFaults") (EVar "idx")) (EVar "stmts")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EStringInterp" (PVar "parts")) (PVar "acc")) (EApp (EApp (EApp (EVar "interpFaults") (EVar "idx")) (EVar "parts")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EGuards" (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardArmsFaults") (EVar "idx")) (EVar "arms")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ERecordCreate" PWild (PVar "fs")) (PVar "acc")) (EApp (EApp (EApp (EVar "fieldsFaults") (EVar "idx")) (EVar "fs")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeHead")) (EApp (EApp (EApp (EVar "fieldsFaults") (EVar "idx")) (EVar "fs")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs")) (PVar "acc")) (EApp (EApp (EApp (EVar "fieldsFaults") (EVar "idx")) (EVar "fs")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EMapLit" PWild (PVar "kvs")) (PVar "acc")) (EApp (EApp (EApp (EVar "kvsFaults") (EVar "idx")) (EVar "kvs")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ESetLit" PWild (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprsFaults") (EVar "idx")) (EVar "es")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EAsPat" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" (PWild (PCon "EMethodRef" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" (PWild (PCon "EDictApp" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" (PWild (PCon "EVarAt" PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" (PWild (PCon "EVarId" PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EMethodAt" PWild PWild (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeMethod")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EDictAt" PWild (PVar "ev")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeMany")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ELoc" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EDoOrigin" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e0")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "ENumLit" PWild (PVar "ev") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeLit")) (EVar "acc")))
(DFunDef false "exprFaults" ((PVar "idx") (PCon "EWideLit" PWild PWild (PVar "ev") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "site") (EVar "idx")) (EVar "ev")) (EVar "ShapeOne")) (EVar "acc")))
(DTypeSig false "armsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "armsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "armsFaults" ((PVar "idx") (PCons (PCon "Arm" PWild (PVar "gs") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "armsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "body")) (EApp (EApp (EApp (EVar "guardsFaults") (EVar "idx")) (EVar "gs")) (EVar "acc")))))
(DTypeSig false "guardsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "guardsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "guardsFaults" ((PVar "idx") (PCons (PCon "GBool" (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DFunDef false "guardsFaults" ((PVar "idx") (PCons (PCon "GBind" PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "guardArmsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "guardArmsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "guardArmsFaults" ((PVar "idx") (PCons (PCon "GuardArm" (PVar "gs") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardArmsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "body")) (EApp (EApp (EApp (EVar "guardsFaults") (EVar "idx")) (EVar "gs")) (EVar "acc")))))
(DTypeSig false "stmtsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "stmtsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "stmtsFaults" ((PVar "idx") (PCons (PVar "s") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "stmtsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "stmtFaults") (EVar "idx")) (EVar "s")) (EVar "acc"))))
(DTypeSig false "stmtFaults" (TyFun (TyCon "EvIndex") (TyFun (TyCon "DoStmt") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "stmtFaults" ((PVar "idx") (PCon "DoExpr" (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "stmtFaults" ((PVar "idx") (PCon "DoBind" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "stmtFaults" ((PVar "idx") (PCon "DoLet" PWild PWild PWild (PVar "e") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "stmtFaults" ((PVar "idx") (PCon "DoAssign" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DFunDef false "stmtFaults" ((PVar "idx") (PCon "DoFieldAssign" PWild PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc")))
(DTypeSig false "interpFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "interpFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "interpFaults" ((PVar "idx") (PCons (PCon "InterpStr" PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "interpFaults") (EVar "idx")) (EVar "rest")) (EVar "acc")))
(DFunDef false "interpFaults" ((PVar "idx") (PCons (PCon "InterpExpr" (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "interpFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "fieldsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "fieldsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fieldsFaults" ((PVar "idx") (PCons (PCon "FieldAssign" PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "fieldsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "kvsFaults" (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyApp (TyCon "List") (TyCon "EvidenceFault"))))))
(DFunDef false "kvsFaults" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "kvsFaults" ((PVar "idx") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "kvsFaults") (EVar "idx")) (EVar "rest")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "v")) (EApp (EApp (EApp (EVar "exprFaults") (EVar "idx")) (EVar "k")) (EVar "acc")))))
