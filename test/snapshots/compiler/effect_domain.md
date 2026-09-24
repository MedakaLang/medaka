# META
source_lines=300
stages=DESUGAR,MARK
# SOURCE
-- Concrete authority domains and canonical row atoms. Domain operations do not
-- depend on inference state, syntax, or dictionary selection.

import support.util.{
  listLen, filterList, joinWith, sortUniqS, startsWith, contains, allList,
  reverseL
}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup, omKeys}

public export data Param =
  | PUnit
  | PPrefix (Option String)
  | PSet (Option (List String))
  | PProduct (List (String, Param))

export
effHoleSrc : String
effHoleSrc = "_"

export
isHoleStr : String -> Bool
isHoleStr s = s == effHoleSrc

export
normHole : Param -> Param
normHole (PPrefix (Some s)) =
  if isHoleStr s then PPrefix None else PPrefix (Some s)
normHole p = p

public export data Atom = Atom String Param

export
atomLabel : Atom -> String
atomLabel (Atom l _) = l

export
atomParam : Atom -> Param
atomParam (Atom _ p) = p

export
subTopOf : Param -> Param
subTopOf (PPrefix _) = PPrefix None
subTopOf (PSet _) = PSet None
subTopOf (PProduct _) = PProduct []
subTopOf _ = PUnit

export
lookupAxis : String -> List (String, Param) -> Option Param
lookupAxis _ [] = None
lookupAxis name ((k, v) :: rest) =
  if name == k then Some v else lookupAxis name rest

export
djoin : Param -> Param -> Param
djoin p1 p2 = djoinN (normHole p1) (normHole p2)

export
djoinN : Param -> Param -> Param
djoinN PUnit PUnit = PUnit
djoinN (PPrefix None) _ = PPrefix None
djoinN _ (PPrefix None) = PPrefix None
djoinN (PPrefix (Some a)) (PPrefix (Some b)) =
  let k = commonPrefixLen a b 0
  if k == 0 then PPrefix None else PPrefix (Some (stringSlice 0 k a))
djoinN (PSet None) _ = PSet None
djoinN _ (PSet None) = PSet None
djoinN (PSet (Some a)) (PSet (Some b)) =
  let u = sortUniqS (a ++ b)
  if listLen u > setCardCap then PSet None else PSet (Some u)
djoinN (PProduct ax) (PProduct bx) =
  productNorm (map (joinAxis ax bx) (axisUnion ax bx))
djoinN p _ = p

export
joinAxis : List (String, Param) ->
  List (String, Param) ->
  String ->
  (String, Param)
joinAxis ax bx name = match (lookupAxis name ax, lookupAxis name bx)
  (Some pa, Some pb) => (name, djoinN pa pb)
  (Some pa, None) => (name, djoinN pa (subTopOf pa))
  (None, Some pb) => (name, djoinN (subTopOf pb) pb)
  (None, None) => (name, PUnit)

export
axisUnion : List (String, Param) -> List (String, Param) -> List String
axisUnion ax bx = sortUniqS (map fst ax ++ map fst bx)

export
productNorm : List (String, Param) -> Param
productNorm axes =
  PProduct (sortAxes (filterList (p => not (isSubTop (snd p))) axes))

export
isSubTop : Param -> Bool
isSubTop (PPrefix None) = True
isSubTop (PSet None) = True
isSubTop (PProduct []) = True
isSubTop PUnit = True
isSubTop _ = False

export
sortAxes : List (String, Param) -> List (String, Param)
sortAxes [] = []
sortAxes (x :: xs) = insertAxis x (sortAxes xs)

export
insertAxis : (String, Param) -> List (String, Param) -> List (String, Param)
insertAxis x [] = [x]
insertAxis x (y :: ys) = match stringCompare (fst x) (fst y)
  Gt => y :: insertAxis x ys
  _ => x :: y :: ys

export
setCardCap : Int
setCardCap = 16

export
commonPrefixLen : String -> String -> Int -> Int
commonPrefixLen a b i =
  if i >= stringLength a || i >= stringLength b then
    i
  else if stringSlice i (i + 1) a == stringSlice i (i + 1) b then
    commonPrefixLen a b (i + 1)
  else
    i

export
drender : Param -> String
drender p = drenderN (normHole p)

export
drenderN : Param -> String
drenderN PUnit = ""
drenderN (PPrefix None) = ""
drenderN (PPrefix (Some s)) = " \"" ++ s ++ "\""
drenderN (PSet None) = ""
drenderN (PSet (Some xs)) = " {" ++ joinWith ", " (map quoteStr xs) ++ "}"
drenderN (PProduct []) = ""
drenderN (PProduct ax) = " " ++ renderProductLit ax

export
quoteStr : String -> String
quoteStr s = "\"" ++ s ++ "\""

export
renderProductLit : List (String, Param) -> String
renderProductLit ax = joinWith " " (map renderAxis ax)

export
renderAxis : (String, Param) -> String
renderAxis (name, p) = "\{name}=\{renderAxisVal p}"

export
renderAxisVal : Param -> String
renderAxisVal (PPrefix (Some s)) = "\"" ++ s ++ "\""
renderAxisVal (PSet (Some xs)) = "{" ++ joinWith ", " (map quoteStr xs) ++ "}"
renderAxisVal _ = ""

export
renderAtom : Atom -> String
renderAtom a = atomLabel a ++ drender (atomParam a)

export
renderAtoms : List Atom -> String
renderAtoms atoms = joinWith ", " (map renderAtom (atomsNorm atoms))

export
atomInsert : Atom -> List Atom -> List Atom
atomInsert x [] = [x]
atomInsert x (y :: ys) = match stringCompare (atomLabel x) (atomLabel y)
  Lt => x :: y :: ys
  Eq => Atom (atomLabel y) (djoin (atomParam x) (atomParam y)) :: ys
  Gt => y :: atomInsert x ys

export
atomsNorm : List Atom -> List Atom
atomsNorm [] = []
atomsNorm [x] = [x]
atomsNorm [x, y] = atomInsert y [x]
atomsNorm [x, y, z] = atomInsert z (atomInsert y [x])
atomsNorm xs = atomsFromIndex (atomIndex xs omEmpty)

-- Rows normally contain one or two labels, where a tree would be needless
-- allocation.  Once a row grows past that fixed small case, index by the
-- already-existing label string.  The map's in-order keys also retain the
-- canonical rendering order.  `djoin x old` deliberately matches atomInsert:
-- a later occurrence is joined into the earlier one in the same direction.
atomIndex : List Atom -> OrdMap Atom -> OrdMap Atom
atomIndex [] m = m
atomIndex (x :: xs) m =
  let label = atomLabel x
  let next = match omLookup label m
    None => x
    Some old => Atom label (djoin (atomParam x) (atomParam old))
  atomIndex xs (omInsert label next m)

atomIndexFirst : List Atom -> OrdMap Atom -> OrdMap Atom
atomIndexFirst [] m = m
atomIndexFirst (x :: xs) m = match omLookup (atomLabel x) m
  None => atomIndexFirst xs (omInsert (atomLabel x) x m)
  Some _ => atomIndexFirst xs m

atomsFromIndex : OrdMap Atom -> List Atom
atomsFromIndex m = atomsFromKeys (omKeys m) m

atomsFromKeys : List String -> OrdMap Atom -> List Atom
atomsFromKeys [] _ = []
atomsFromKeys (label :: labels) m = match omLookup label m
  Some atom => atom :: atomsFromKeys labels m
  None => atomsFromKeys labels m

export
atomsNormGo : List Atom -> List Atom -> List Atom
atomsNormGo xs acc = atomsNorm (acc ++ xs)

export
atomsUnion : List Atom -> List Atom -> List Atom
atomsUnion a b = atomsNorm (a ++ b)

export
prefixConcrete : String -> String
prefixConcrete s =
  let n = stringLength s
  if n > 0 && stringSlice (n - 1) n s == "*" then stringSlice 0 (n - 1) s else s

export
dsub : Param -> Param -> Bool
dsub p1 p2 = dsubN (normHole p1) (normHole p2)

export
dsubN : Param -> Param -> Bool
dsubN PUnit PUnit = True
dsubN _ (PPrefix None) = True
dsubN (PPrefix (Some a)) (PPrefix (Some b)) =
  startsWith (prefixConcrete b) (prefixConcrete a)
dsubN (PPrefix None) (PPrefix (Some _)) = False
dsubN _ (PSet None) = True
dsubN (PSet (Some a)) (PSet (Some b)) = subsetStr a b
dsubN (PSet None) (PSet (Some _)) = False
dsubN _ (PProduct []) = True
dsubN (PProduct ax) (PProduct bx) = allList (axisSub ax) bx
dsubN _ _ = False

export
axisSub : List (String, Param) -> (String, Param) -> Bool
axisSub ax (name, bp) = dsubN (lookupAxisOrTop name ax bp) bp

export
lookupAxisOrTop : String -> List (String, Param) -> Param -> Param
lookupAxisOrTop name ax bp = match lookupAxis name ax
  Some v => v
  None => subTopOf bp

export
subsetStr : List String -> List String -> Bool
subsetStr [] _ = True
subsetStr (x :: xs) b = if contains x b then subsetStr xs b else False

export
atomsDiff : List Atom -> List Atom -> List Atom
atomsDiff [] _ = []
atomsDiff xs [] = xs
atomsDiff [x] ys = atomsDiffOne x ys
atomsDiff [x, y] ys = atomsDiffOne x ys ++ atomsDiffOne y ys
atomsDiff xs [y] = atomsDiffOneAgainst xs y
atomsDiff xs ys = reverseL (atomsDiffIndexed xs (atomIndexFirst ys omEmpty) [])

-- The one-bound case is common for a single capability check and avoids a map.
-- Its first-match behavior is identical to `findAtom` on an unnormalised row.
atomsDiffOne : Atom -> List Atom -> List Atom
atomsDiffOne x ys = match findAtom (atomLabel x) ys
  None => [x]
  Some y => if dsub (atomParam x) (atomParam y) then [] else [x]

atomsDiffOneAgainst : List Atom -> Atom -> List Atom
atomsDiffOneAgainst xs y = reverseL (atomsDiffOneAgainstGo xs y [])

atomsDiffOneAgainstGo : List Atom -> Atom -> List Atom -> List Atom
atomsDiffOneAgainstGo [] _ acc = acc
atomsDiffOneAgainstGo (x :: xs) y acc =
  if atomLabel x == atomLabel y && dsub (atomParam x) (atomParam y) then
    atomsDiffOneAgainstGo xs y acc
  else
    atomsDiffOneAgainstGo xs y (x :: acc)

atomsDiffIndexed : List Atom -> OrdMap Atom -> List Atom -> List Atom
atomsDiffIndexed [] _ acc = acc
atomsDiffIndexed (x :: xs) index acc = match omLookup (atomLabel x) index
  Some y =>
    if dsub (atomParam x) (atomParam y) then
      atomsDiffIndexed xs index acc
    else
      atomsDiffIndexed xs index (x :: acc)
  None => atomsDiffIndexed xs index (x :: acc)

export
findAtom : String -> List Atom -> Option Atom
findAtom _ [] = None
findAtom l (y :: ys) = if l == atomLabel y then Some y else findAtom l ys
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false) (mem "reverseL" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DData Public "Param" () ((variant "PUnit" (ConPos)) (variant "PPrefix" (ConPos (TyApp (TyCon "Option") (TyCon "String")))) (variant "PSet" (ConPos (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))) (variant "PProduct" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))) ())
(DTypeSig true "effHoleSrc" (TyCon "String"))
(DFunDef false "effHoleSrc" () (ELit (LString "_")))
(DTypeSig true "isHoleStr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHoleStr" ((PVar "s")) (EBinOp "==" (EVar "s") (EVar "effHoleSrc")))
(DTypeSig true "normHole" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "normHole" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EIf (EApp (EVar "isHoleStr") (EVar "s")) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "normHole" ((PVar "p")) (EVar "p"))
(DData Public "Atom" () ((variant "Atom" (ConPos (TyCon "String") (TyCon "Param")))) ())
(DTypeSig true "atomLabel" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "atomLabel" ((PCon "Atom" (PVar "l") PWild)) (EVar "l"))
(DTypeSig true "atomParam" (TyFun (TyCon "Atom") (TyCon "Param")))
(DFunDef false "atomParam" ((PCon "Atom" PWild (PVar "p"))) (EVar "p"))
(DTypeSig true "subTopOf" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "subTopOf" ((PCon "PPrefix" PWild)) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PSet" PWild)) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PProduct" PWild)) (EApp (EVar "PProduct") (EListLit)))
(DFunDef false "subTopOf" (PWild) (EVar "PUnit"))
(DTypeSig true "lookupAxis" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "lookupAxis" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAxis" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "rest"))))
(DTypeSig true "djoin" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoin" ((PVar "p1") (PVar "p2")) (EApp (EApp (EVar "djoinN") (EApp (EVar "normHole") (EVar "p1"))) (EApp (EVar "normHole") (EVar "p2"))))
(DTypeSig true "djoinN" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoinN" ((PCon "PUnit") (PCon "PUnit")) (EVar "PUnit"))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "None")) PWild) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PPrefix" (PCon "None"))) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "a")) (EVar "b")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "k")) (EVar "a"))))))))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "None")) PWild) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PSet" (PCon "None"))) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EBlock (DoLet false false (PVar "u") (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "a") (EVar "b")))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "u")) (EVar "setCardCap")) (EApp (EVar "PSet") (EVar "None")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "u")))))))
(DFunDef false "djoinN" ((PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EApp (EVar "productNorm") (EApp (EApp (EVar "map") (EApp (EApp (EVar "joinAxis") (EVar "ax")) (EVar "bx"))) (EApp (EApp (EVar "axisUnion") (EVar "ax")) (EVar "bx")))))
(DFunDef false "djoinN" ((PVar "p") PWild) (EVar "p"))
(DTypeSig true "joinAxis" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "joinAxis" ((PVar "ax") (PVar "bx") (PVar "name")) (EMatch (ETuple (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "bx"))) (arm (PTuple (PCon "Some" (PVar "pa")) (PCon "Some" (PVar "pb"))) () (ETuple (EVar "name") (EApp (EApp (EVar "djoinN") (EVar "pa")) (EVar "pb")))) (arm (PTuple (PCon "Some" (PVar "pa")) (PCon "None")) () (ETuple (EVar "name") (EApp (EApp (EVar "djoinN") (EVar "pa")) (EApp (EVar "subTopOf") (EVar "pa"))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "pb"))) () (ETuple (EVar "name") (EApp (EApp (EVar "djoinN") (EApp (EVar "subTopOf") (EVar "pb"))) (EVar "pb")))) (arm (PTuple (PCon "None") (PCon "None")) () (ETuple (EVar "name") (EVar "PUnit")))))
(DTypeSig true "axisUnion" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "axisUnion" ((PVar "ax") (PVar "bx")) (EApp (EVar "sortUniqS") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ax")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "bx")))))
(DTypeSig true "productNorm" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Param")))
(DFunDef false "productNorm" ((PVar "axes")) (EApp (EVar "PProduct") (EApp (EVar "sortAxes") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "p")))))) (EVar "axes")))))
(DTypeSig true "isSubTop" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "isSubTop" ((PCon "PPrefix" (PCon "None"))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PProduct" (PList))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PUnit")) (EVar "True"))
(DFunDef false "isSubTop" (PWild) (EVar "False"))
(DTypeSig true "sortAxes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "sortAxes" ((PList)) (EListLit))
(DFunDef false "sortAxes" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "insertAxis") (EVar "x")) (EApp (EVar "sortAxes") (EVar "xs"))))
(DTypeSig true "insertAxis" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "insertAxis" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "insertAxis" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "fst") (EVar "x"))) (EApp (EVar "fst") (EVar "y"))) (arm (PCon "Gt") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "insertAxis") (EVar "x")) (EVar "ys")))) (arm PWild () (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))))))
(DTypeSig true "setCardCap" (TyCon "Int"))
(DFunDef false "setCardCap" () (ELit (LInt 16)))
(DTypeSig true "commonPrefixLen" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "commonPrefixLen" ((PVar "a") (PVar "b") (PVar "i")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "a"))) (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "b")))) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "a")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "b"))) (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i"))))
(DTypeSig true "drender" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "drender" ((PVar "p")) (EApp (EVar "drenderN") (EApp (EVar "normHole") (EVar "p"))))
(DTypeSig true "drenderN" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "drenderN" ((PCon "PUnit")) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PPrefix" (PCon "None"))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EBinOp "++" (EBinOp "++" (ELit (LString " \"")) (EVar "s")) (ELit (LString "\""))))
(DFunDef false "drenderN" ((PCon "PSet" (PCon "None"))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EBinOp "++" (EBinOp "++" (ELit (LString " {")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoteStr")) (EVar "xs")))) (ELit (LString "}"))))
(DFunDef false "drenderN" ((PCon "PProduct" (PList))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PProduct" (PVar "ax"))) (EBinOp "++" (ELit (LString " ")) (EApp (EVar "renderProductLit") (EVar "ax"))))
(DTypeSig true "quoteStr" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteStr" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DTypeSig true "renderProductLit" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "renderProductLit" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "renderAxis")) (EVar "ax"))))
(DTypeSig true "renderAxis" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "renderAxis" ((PTuple (PVar "name") (PVar "p"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "="))) (EApp (EVar "display") (EApp (EVar "renderAxisVal") (EVar "p")))) (ELit (LString ""))))
(DTypeSig true "renderAxisVal" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "renderAxisVal" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DFunDef false "renderAxisVal" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EBinOp "++" (EBinOp "++" (ELit (LString "{")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoteStr")) (EVar "xs")))) (ELit (LString "}"))))
(DFunDef false "renderAxisVal" (PWild) (ELit (LString "")))
(DTypeSig true "renderAtom" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "renderAtom" ((PVar "a")) (EBinOp "++" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EVar "drender") (EApp (EVar "atomParam") (EVar "a")))))
(DTypeSig true "renderAtoms" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "renderAtoms" ((PVar "atoms")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "renderAtom")) (EApp (EVar "atomsNorm") (EVar "atoms")))))
(DTypeSig true "atomInsert" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "atomInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "atomLabel") (EVar "x"))) (EApp (EVar "atomLabel") (EVar "y"))) (arm (PCon "Lt") () (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys")))) (arm (PCon "Eq") () (EBinOp "::" (EApp (EApp (EVar "Atom") (EApp (EVar "atomLabel") (EVar "y"))) (EApp (EApp (EVar "djoin") (EApp (EVar "atomParam") (EVar "x"))) (EApp (EVar "atomParam") (EVar "y")))) (EVar "ys"))) (arm (PCon "Gt") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "atomInsert") (EVar "x")) (EVar "ys"))))))
(DTypeSig true "atomsNorm" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "atomsNorm" ((PList)) (EListLit))
(DFunDef false "atomsNorm" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "atomsNorm" ((PList (PVar "x") (PVar "y"))) (EApp (EApp (EVar "atomInsert") (EVar "y")) (EListLit (EVar "x"))))
(DFunDef false "atomsNorm" ((PList (PVar "x") (PVar "y") (PVar "z"))) (EApp (EApp (EVar "atomInsert") (EVar "z")) (EApp (EApp (EVar "atomInsert") (EVar "y")) (EListLit (EVar "x")))))
(DFunDef false "atomsNorm" ((PVar "xs")) (EApp (EVar "atomsFromIndex") (EApp (EApp (EVar "atomIndex") (EVar "xs")) (EVar "omEmpty"))))
(DTypeSig false "atomIndex" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "OrdMap") (TyCon "Atom")))))
(DFunDef false "atomIndex" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "atomIndex" ((PCons (PVar "x") (PVar "xs")) (PVar "m")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "x"))) (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "omLookup") (EVar "label")) (EVar "m")) (arm (PCon "None") () (EVar "x")) (arm (PCon "Some" (PVar "old")) () (EApp (EApp (EVar "Atom") (EVar "label")) (EApp (EApp (EVar "djoin") (EApp (EVar "atomParam") (EVar "x"))) (EApp (EVar "atomParam") (EVar "old"))))))) (DoExpr (EApp (EApp (EVar "atomIndex") (EVar "xs")) (EApp (EApp (EApp (EVar "omInsert") (EVar "label")) (EVar "next")) (EVar "m"))))))
(DTypeSig false "atomIndexFirst" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "OrdMap") (TyCon "Atom")))))
(DFunDef false "atomIndexFirst" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "atomIndexFirst" ((PCons (PVar "x") (PVar "xs")) (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "atomLabel") (EVar "x"))) (EVar "m")) (arm (PCon "None") () (EApp (EApp (EVar "atomIndexFirst") (EVar "xs")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "atomLabel") (EVar "x"))) (EVar "x")) (EVar "m")))) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "atomIndexFirst") (EVar "xs")) (EVar "m")))))
(DTypeSig false "atomsFromIndex" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "atomsFromIndex" ((PVar "m")) (EApp (EApp (EVar "atomsFromKeys") (EApp (EVar "omKeys") (EVar "m"))) (EVar "m")))
(DTypeSig false "atomsFromKeys" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsFromKeys" ((PList) PWild) (EListLit))
(DFunDef false "atomsFromKeys" ((PCons (PVar "label") (PVar "labels")) (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "label")) (EVar "m")) (arm (PCon "Some" (PVar "atom")) () (EBinOp "::" (EVar "atom") (EApp (EApp (EVar "atomsFromKeys") (EVar "labels")) (EVar "m")))) (arm (PCon "None") () (EApp (EApp (EVar "atomsFromKeys") (EVar "labels")) (EVar "m")))))
(DTypeSig true "atomsNormGo" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsNormGo" ((PVar "xs") (PVar "acc")) (EApp (EVar "atomsNorm") (EBinOp "++" (EVar "acc") (EVar "xs"))))
(DTypeSig true "atomsUnion" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsUnion" ((PVar "a") (PVar "b")) (EApp (EVar "atomsNorm") (EBinOp "++" (EVar "a") (EVar "b"))))
(DTypeSig true "prefixConcrete" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "prefixConcrete" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "*")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig true "dsub" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "dsub" ((PVar "p1") (PVar "p2")) (EApp (EApp (EVar "dsubN") (EApp (EVar "normHole") (EVar "p1"))) (EApp (EVar "normHole") (EVar "p2"))))
(DTypeSig true "dsubN" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "dsubN" ((PCon "PUnit") (PCon "PUnit")) (EVar "True"))
(DFunDef false "dsubN" (PWild (PCon "PPrefix" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "startsWith") (EApp (EVar "prefixConcrete") (EVar "b"))) (EApp (EVar "prefixConcrete") (EVar "a"))))
(DFunDef false "dsubN" ((PCon "PPrefix" (PCon "None")) (PCon "PPrefix" (PCon "Some" PWild))) (EVar "False"))
(DFunDef false "dsubN" (PWild (PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "subsetStr") (EVar "a")) (EVar "b")))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "None")) (PCon "PSet" (PCon "Some" PWild))) (EVar "False"))
(DFunDef false "dsubN" (PWild (PCon "PProduct" (PList))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EApp (EApp (EVar "allList") (EApp (EVar "axisSub") (EVar "ax"))) (EVar "bx")))
(DFunDef false "dsubN" (PWild PWild) (EVar "False"))
(DTypeSig true "axisSub" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "Bool"))))
(DFunDef false "axisSub" ((PVar "ax") (PTuple (PVar "name") (PVar "bp"))) (EApp (EApp (EVar "dsubN") (EApp (EApp (EApp (EVar "lookupAxisOrTop") (EVar "name")) (EVar "ax")) (EVar "bp"))) (EVar "bp")))
(DTypeSig true "lookupAxisOrTop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "Param") (TyCon "Param")))))
(DFunDef false "lookupAxisOrTop" ((PVar "name") (PVar "ax") (PVar "bp")) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "subTopOf") (EVar "bp")))))
(DTypeSig true "subsetStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "subsetStr" ((PList) PWild) (EVar "True"))
(DFunDef false "subsetStr" ((PCons (PVar "x") (PVar "xs")) (PVar "b")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "b")) (EApp (EApp (EVar "subsetStr") (EVar "xs")) (EVar "b")) (EVar "False")))
(DTypeSig true "atomsDiff" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiff" ((PList) PWild) (EListLit))
(DFunDef false "atomsDiff" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "atomsDiff" ((PList (PVar "x")) (PVar "ys")) (EApp (EApp (EVar "atomsDiffOne") (EVar "x")) (EVar "ys")))
(DFunDef false "atomsDiff" ((PList (PVar "x") (PVar "y")) (PVar "ys")) (EBinOp "++" (EApp (EApp (EVar "atomsDiffOne") (EVar "x")) (EVar "ys")) (EApp (EApp (EVar "atomsDiffOne") (EVar "y")) (EVar "ys"))))
(DFunDef false "atomsDiff" ((PVar "xs") (PList (PVar "y"))) (EApp (EApp (EVar "atomsDiffOneAgainst") (EVar "xs")) (EVar "y")))
(DFunDef false "atomsDiff" ((PVar "xs") (PVar "ys")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EApp (EApp (EVar "atomIndexFirst") (EVar "ys")) (EVar "omEmpty"))) (EListLit))))
(DTypeSig false "atomsDiffOne" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiffOne" ((PVar "x") (PVar "ys")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomLabel") (EVar "x"))) (EVar "ys")) (arm (PCon "None") () (EListLit (EVar "x"))) (arm (PCon "Some" (PVar "y")) () (EIf (EApp (EApp (EVar "dsub") (EApp (EVar "atomParam") (EVar "x"))) (EApp (EVar "atomParam") (EVar "y"))) (EListLit) (EListLit (EVar "x"))))))
(DTypeSig false "atomsDiffOneAgainst" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "Atom") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiffOneAgainst" ((PVar "xs") (PVar "y")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EListLit))))
(DTypeSig false "atomsDiffOneAgainstGo" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsDiffOneAgainstGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "atomsDiffOneAgainstGo" ((PCons (PVar "x") (PVar "xs")) (PVar "y") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomLabel") (EVar "x")) (EApp (EVar "atomLabel") (EVar "y"))) (EApp (EApp (EVar "dsub") (EApp (EVar "atomParam") (EVar "x"))) (EApp (EVar "atomParam") (EVar "y")))) (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EVar "acc")) (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EBinOp "::" (EVar "x") (EVar "acc")))))
(DTypeSig false "atomsDiffIndexed" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsDiffIndexed" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "atomsDiffIndexed" ((PCons (PVar "x") (PVar "xs")) (PVar "index") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "atomLabel") (EVar "x"))) (EVar "index")) (arm (PCon "Some" (PVar "y")) () (EIf (EApp (EApp (EVar "dsub") (EApp (EVar "atomParam") (EVar "x"))) (EApp (EVar "atomParam") (EVar "y"))) (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EVar "index")) (EVar "acc")) (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EVar "index")) (EBinOp "::" (EVar "x") (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EVar "index")) (EBinOp "::" (EVar "x") (EVar "acc"))))))
(DTypeSig true "findAtom" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "Option") (TyCon "Atom")))))
(DFunDef false "findAtom" (PWild (PList)) (EVar "None"))
(DFunDef false "findAtom" ((PVar "l") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "l") (EApp (EVar "atomLabel") (EVar "y"))) (EApp (EVar "Some") (EVar "y")) (EApp (EApp (EVar "findAtom") (EVar "l")) (EVar "ys"))))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false) (mem "reverseL" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DData Public "Param" () ((variant "PUnit" (ConPos)) (variant "PPrefix" (ConPos (TyApp (TyCon "Option") (TyCon "String")))) (variant "PSet" (ConPos (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))) (variant "PProduct" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))) ())
(DTypeSig true "effHoleSrc" (TyCon "String"))
(DFunDef false "effHoleSrc" () (ELit (LString "_")))
(DTypeSig true "isHoleStr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHoleStr" ((PVar "s")) (EBinOp "==" (EVar "s") (EVar "effHoleSrc")))
(DTypeSig true "normHole" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "normHole" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EIf (EApp (EVar "isHoleStr") (EVar "s")) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "normHole" ((PVar "p")) (EVar "p"))
(DData Public "Atom" () ((variant "Atom" (ConPos (TyCon "String") (TyCon "Param")))) ())
(DTypeSig true "atomLabel" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "atomLabel" ((PCon "Atom" (PVar "l") PWild)) (EVar "l"))
(DTypeSig true "atomParam" (TyFun (TyCon "Atom") (TyCon "Param")))
(DFunDef false "atomParam" ((PCon "Atom" PWild (PVar "p"))) (EVar "p"))
(DTypeSig true "subTopOf" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "subTopOf" ((PCon "PPrefix" PWild)) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PSet" PWild)) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PProduct" PWild)) (EApp (EVar "PProduct") (EListLit)))
(DFunDef false "subTopOf" (PWild) (EVar "PUnit"))
(DTypeSig true "lookupAxis" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "lookupAxis" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAxis" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "rest"))))
(DTypeSig true "djoin" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoin" ((PVar "p1") (PVar "p2")) (EApp (EApp (EVar "djoinN") (EApp (EVar "normHole") (EVar "p1"))) (EApp (EVar "normHole") (EVar "p2"))))
(DTypeSig true "djoinN" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoinN" ((PCon "PUnit") (PCon "PUnit")) (EVar "PUnit"))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "None")) PWild) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PPrefix" (PCon "None"))) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "a")) (EVar "b")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "k")) (EVar "a"))))))))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "None")) PWild) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PSet" (PCon "None"))) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EBlock (DoLet false false (PVar "u") (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "a") (EVar "b")))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "u")) (EVar "setCardCap")) (EApp (EVar "PSet") (EVar "None")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "u")))))))
(DFunDef false "djoinN" ((PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EApp (EVar "productNorm") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "joinAxis") (EVar "ax")) (EVar "bx"))) (EApp (EApp (EVar "axisUnion") (EVar "ax")) (EVar "bx")))))
(DFunDef false "djoinN" ((PVar "p") PWild) (EVar "p"))
(DTypeSig true "joinAxis" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "joinAxis" ((PVar "ax") (PVar "bx") (PVar "name")) (EMatch (ETuple (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "bx"))) (arm (PTuple (PCon "Some" (PVar "pa")) (PCon "Some" (PVar "pb"))) () (ETuple (EVar "name") (EApp (EApp (EVar "djoinN") (EVar "pa")) (EVar "pb")))) (arm (PTuple (PCon "Some" (PVar "pa")) (PCon "None")) () (ETuple (EVar "name") (EApp (EApp (EVar "djoinN") (EVar "pa")) (EApp (EVar "subTopOf") (EVar "pa"))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "pb"))) () (ETuple (EVar "name") (EApp (EApp (EVar "djoinN") (EApp (EVar "subTopOf") (EVar "pb"))) (EVar "pb")))) (arm (PTuple (PCon "None") (PCon "None")) () (ETuple (EVar "name") (EVar "PUnit")))))
(DTypeSig true "axisUnion" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "axisUnion" ((PVar "ax") (PVar "bx")) (EApp (EVar "sortUniqS") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ax")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "bx")))))
(DTypeSig true "productNorm" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Param")))
(DFunDef false "productNorm" ((PVar "axes")) (EApp (EVar "PProduct") (EApp (EVar "sortAxes") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "p")))))) (EVar "axes")))))
(DTypeSig true "isSubTop" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "isSubTop" ((PCon "PPrefix" (PCon "None"))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PProduct" (PList))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PUnit")) (EVar "True"))
(DFunDef false "isSubTop" (PWild) (EVar "False"))
(DTypeSig true "sortAxes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "sortAxes" ((PList)) (EListLit))
(DFunDef false "sortAxes" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "insertAxis") (EVar "x")) (EApp (EVar "sortAxes") (EVar "xs"))))
(DTypeSig true "insertAxis" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "insertAxis" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "insertAxis" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "fst") (EVar "x"))) (EApp (EVar "fst") (EVar "y"))) (arm (PCon "Gt") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "insertAxis") (EVar "x")) (EVar "ys")))) (arm PWild () (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))))))
(DTypeSig true "setCardCap" (TyCon "Int"))
(DFunDef false "setCardCap" () (ELit (LInt 16)))
(DTypeSig true "commonPrefixLen" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "commonPrefixLen" ((PVar "a") (PVar "b") (PVar "i")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "a"))) (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "b")))) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "a")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "b"))) (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i"))))
(DTypeSig true "drender" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "drender" ((PVar "p")) (EApp (EVar "drenderN") (EApp (EVar "normHole") (EVar "p"))))
(DTypeSig true "drenderN" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "drenderN" ((PCon "PUnit")) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PPrefix" (PCon "None"))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EBinOp "++" (EBinOp "++" (ELit (LString " \"")) (EVar "s")) (ELit (LString "\""))))
(DFunDef false "drenderN" ((PCon "PSet" (PCon "None"))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EBinOp "++" (EBinOp "++" (ELit (LString " {")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoteStr")) (EVar "xs")))) (ELit (LString "}"))))
(DFunDef false "drenderN" ((PCon "PProduct" (PList))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PProduct" (PVar "ax"))) (EBinOp "++" (ELit (LString " ")) (EApp (EVar "renderProductLit") (EVar "ax"))))
(DTypeSig true "quoteStr" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteStr" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DTypeSig true "renderProductLit" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "renderProductLit" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "renderAxis")) (EVar "ax"))))
(DTypeSig true "renderAxis" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "renderAxis" ((PTuple (PVar "name") (PVar "p"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EApp (EVar "renderAxisVal") (EVar "p")))) (ELit (LString ""))))
(DTypeSig true "renderAxisVal" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "renderAxisVal" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DFunDef false "renderAxisVal" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EBinOp "++" (EBinOp "++" (ELit (LString "{")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoteStr")) (EVar "xs")))) (ELit (LString "}"))))
(DFunDef false "renderAxisVal" (PWild) (ELit (LString "")))
(DTypeSig true "renderAtom" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "renderAtom" ((PVar "a")) (EBinOp "++" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EVar "drender") (EApp (EVar "atomParam") (EVar "a")))))
(DTypeSig true "renderAtoms" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "renderAtoms" ((PVar "atoms")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "renderAtom")) (EApp (EVar "atomsNorm") (EVar "atoms")))))
(DTypeSig true "atomInsert" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "atomInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "atomLabel") (EVar "x"))) (EApp (EVar "atomLabel") (EVar "y"))) (arm (PCon "Lt") () (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys")))) (arm (PCon "Eq") () (EBinOp "::" (EApp (EApp (EVar "Atom") (EApp (EVar "atomLabel") (EVar "y"))) (EApp (EApp (EVar "djoin") (EApp (EVar "atomParam") (EVar "x"))) (EApp (EVar "atomParam") (EVar "y")))) (EVar "ys"))) (arm (PCon "Gt") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "atomInsert") (EVar "x")) (EVar "ys"))))))
(DTypeSig true "atomsNorm" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "atomsNorm" ((PList)) (EListLit))
(DFunDef false "atomsNorm" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "atomsNorm" ((PList (PVar "x") (PVar "y"))) (EApp (EApp (EVar "atomInsert") (EVar "y")) (EListLit (EVar "x"))))
(DFunDef false "atomsNorm" ((PList (PVar "x") (PVar "y") (PVar "z"))) (EApp (EApp (EVar "atomInsert") (EVar "z")) (EApp (EApp (EVar "atomInsert") (EVar "y")) (EListLit (EVar "x")))))
(DFunDef false "atomsNorm" ((PVar "xs")) (EApp (EVar "atomsFromIndex") (EApp (EApp (EVar "atomIndex") (EVar "xs")) (EVar "omEmpty"))))
(DTypeSig false "atomIndex" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "OrdMap") (TyCon "Atom")))))
(DFunDef false "atomIndex" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "atomIndex" ((PCons (PVar "x") (PVar "xs")) (PVar "m")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "x"))) (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "omLookup") (EVar "label")) (EVar "m")) (arm (PCon "None") () (EVar "x")) (arm (PCon "Some" (PVar "old")) () (EApp (EApp (EVar "Atom") (EVar "label")) (EApp (EApp (EVar "djoin") (EApp (EVar "atomParam") (EVar "x"))) (EApp (EVar "atomParam") (EVar "old"))))))) (DoExpr (EApp (EApp (EVar "atomIndex") (EVar "xs")) (EApp (EApp (EApp (EVar "omInsert") (EVar "label")) (EVar "next")) (EVar "m"))))))
(DTypeSig false "atomIndexFirst" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "OrdMap") (TyCon "Atom")))))
(DFunDef false "atomIndexFirst" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "atomIndexFirst" ((PCons (PVar "x") (PVar "xs")) (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "atomLabel") (EVar "x"))) (EVar "m")) (arm (PCon "None") () (EApp (EApp (EVar "atomIndexFirst") (EVar "xs")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "atomLabel") (EVar "x"))) (EVar "x")) (EVar "m")))) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "atomIndexFirst") (EVar "xs")) (EVar "m")))))
(DTypeSig false "atomsFromIndex" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "atomsFromIndex" ((PVar "m")) (EApp (EApp (EVar "atomsFromKeys") (EApp (EVar "omKeys") (EVar "m"))) (EVar "m")))
(DTypeSig false "atomsFromKeys" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsFromKeys" ((PList) PWild) (EListLit))
(DFunDef false "atomsFromKeys" ((PCons (PVar "label") (PVar "labels")) (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "label")) (EVar "m")) (arm (PCon "Some" (PVar "atom")) () (EBinOp "::" (EVar "atom") (EApp (EApp (EVar "atomsFromKeys") (EVar "labels")) (EVar "m")))) (arm (PCon "None") () (EApp (EApp (EVar "atomsFromKeys") (EVar "labels")) (EVar "m")))))
(DTypeSig true "atomsNormGo" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsNormGo" ((PVar "xs") (PVar "acc")) (EApp (EVar "atomsNorm") (EBinOp "++" (EVar "acc") (EVar "xs"))))
(DTypeSig true "atomsUnion" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsUnion" ((PVar "a") (PVar "b")) (EApp (EVar "atomsNorm") (EBinOp "++" (EVar "a") (EVar "b"))))
(DTypeSig true "prefixConcrete" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "prefixConcrete" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "*")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig true "dsub" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "dsub" ((PVar "p1") (PVar "p2")) (EApp (EApp (EVar "dsubN") (EApp (EVar "normHole") (EVar "p1"))) (EApp (EVar "normHole") (EVar "p2"))))
(DTypeSig true "dsubN" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "dsubN" ((PCon "PUnit") (PCon "PUnit")) (EVar "True"))
(DFunDef false "dsubN" (PWild (PCon "PPrefix" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "startsWith") (EApp (EVar "prefixConcrete") (EVar "b"))) (EApp (EVar "prefixConcrete") (EVar "a"))))
(DFunDef false "dsubN" ((PCon "PPrefix" (PCon "None")) (PCon "PPrefix" (PCon "Some" PWild))) (EVar "False"))
(DFunDef false "dsubN" (PWild (PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "subsetStr") (EVar "a")) (EVar "b")))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "None")) (PCon "PSet" (PCon "Some" PWild))) (EVar "False"))
(DFunDef false "dsubN" (PWild (PCon "PProduct" (PList))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EApp (EApp (EVar "allList") (EApp (EVar "axisSub") (EVar "ax"))) (EVar "bx")))
(DFunDef false "dsubN" (PWild PWild) (EVar "False"))
(DTypeSig true "axisSub" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "Bool"))))
(DFunDef false "axisSub" ((PVar "ax") (PTuple (PVar "name") (PVar "bp"))) (EApp (EApp (EVar "dsubN") (EApp (EApp (EApp (EVar "lookupAxisOrTop") (EVar "name")) (EVar "ax")) (EVar "bp"))) (EVar "bp")))
(DTypeSig true "lookupAxisOrTop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "Param") (TyCon "Param")))))
(DFunDef false "lookupAxisOrTop" ((PVar "name") (PVar "ax") (PVar "bp")) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "subTopOf") (EVar "bp")))))
(DTypeSig true "subsetStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "subsetStr" ((PList) PWild) (EVar "True"))
(DFunDef false "subsetStr" ((PCons (PVar "x") (PVar "xs")) (PVar "b")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "b")) (EApp (EApp (EVar "subsetStr") (EVar "xs")) (EVar "b")) (EVar "False")))
(DTypeSig true "atomsDiff" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiff" ((PList) PWild) (EListLit))
(DFunDef false "atomsDiff" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "atomsDiff" ((PList (PVar "x")) (PVar "ys")) (EApp (EApp (EVar "atomsDiffOne") (EVar "x")) (EVar "ys")))
(DFunDef false "atomsDiff" ((PList (PVar "x") (PVar "y")) (PVar "ys")) (EBinOp "++" (EApp (EApp (EVar "atomsDiffOne") (EVar "x")) (EVar "ys")) (EApp (EApp (EVar "atomsDiffOne") (EVar "y")) (EVar "ys"))))
(DFunDef false "atomsDiff" ((PVar "xs") (PList (PVar "y"))) (EApp (EApp (EVar "atomsDiffOneAgainst") (EVar "xs")) (EVar "y")))
(DFunDef false "atomsDiff" ((PVar "xs") (PVar "ys")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EApp (EApp (EVar "atomIndexFirst") (EVar "ys")) (EVar "omEmpty"))) (EListLit))))
(DTypeSig false "atomsDiffOne" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiffOne" ((PVar "x") (PVar "ys")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomLabel") (EVar "x"))) (EVar "ys")) (arm (PCon "None") () (EListLit (EVar "x"))) (arm (PCon "Some" (PVar "y")) () (EIf (EApp (EApp (EVar "dsub") (EApp (EVar "atomParam") (EVar "x"))) (EApp (EVar "atomParam") (EVar "y"))) (EListLit) (EListLit (EVar "x"))))))
(DTypeSig false "atomsDiffOneAgainst" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "Atom") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiffOneAgainst" ((PVar "xs") (PVar "y")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EListLit))))
(DTypeSig false "atomsDiffOneAgainstGo" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsDiffOneAgainstGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "atomsDiffOneAgainstGo" ((PCons (PVar "x") (PVar "xs")) (PVar "y") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomLabel") (EVar "x")) (EApp (EVar "atomLabel") (EVar "y"))) (EApp (EApp (EVar "dsub") (EApp (EVar "atomParam") (EVar "x"))) (EApp (EVar "atomParam") (EVar "y")))) (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EVar "acc")) (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EBinOp "::" (EVar "x") (EVar "acc")))))
(DTypeSig false "atomsDiffIndexed" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsDiffIndexed" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "atomsDiffIndexed" ((PCons (PVar "x") (PVar "xs")) (PVar "index") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "atomLabel") (EVar "x"))) (EMethodRef "index")) (arm (PCon "Some" (PVar "y")) () (EIf (EApp (EApp (EVar "dsub") (EApp (EVar "atomParam") (EVar "x"))) (EApp (EVar "atomParam") (EVar "y"))) (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EMethodRef "index")) (EVar "acc")) (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EMethodRef "index")) (EBinOp "::" (EVar "x") (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EMethodRef "index")) (EBinOp "::" (EVar "x") (EVar "acc"))))))
(DTypeSig true "findAtom" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "Option") (TyCon "Atom")))))
(DFunDef false "findAtom" (PWild (PList)) (EVar "None"))
(DFunDef false "findAtom" ((PVar "l") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "l") (EApp (EVar "atomLabel") (EVar "y"))) (EApp (EVar "Some") (EVar "y")) (EApp (EApp (EVar "findAtom") (EVar "l")) (EVar "ys"))))
