# META
source_lines=223
stages=DESUGAR,MARK
# SOURCE
-- Concrete authority domains: the lattice each effect label's parameter is
-- drawn from. Domain operations do not depend on inference state, syntax, or
-- dictionary selection; atoms and rows are built over them in `effect_rows`.

import support.util.{
  listLen, filterList, joinWith, sortUniqS, startsWith, contains, allList
}

public export data Param =
  | PUnit
  | PPrefix (Option String)
  | PSet (Option (List String))
  | PProduct (List (String, Param))

-- Canonical form of a parameter. The empty prefix denotes the Prefix domain's
-- top: `""` is a prefix of every path, so its join with any prefix is top and
-- top must cover it. One representation keeps join, coverage, rendering and a
-- solver's covered-atom skip in agreement; a producer that abstracts a value
-- to `""` builds the top parameter through this function.
export
canonParam : Param -> Param
canonParam (PPrefix (Some s)) =
  if s == "" then PPrefix None else PPrefix (Some s)
canonParam (PProduct ax) = productNorm ax
canonParam p = p

-- A Product's top keeps its declared axis SCHEMA (each axis at its own top,
-- in declaration order), so a domain top read off a label or a variable can
-- say which axis a bare literal lifts into and which axes a written product
-- may name.  A VALUE normalises the top axes away (`productNorm`), so
-- `PProduct []` and a schema top are the same element of the order.
export
subTopOf : Param -> Param
subTopOf (PPrefix _) = PPrefix None
subTopOf (PSet _) = PSet None
subTopOf (PProduct ax) = PProduct (map (a => (fst a, subTopOf (snd a))) ax)
subTopOf _ = PUnit

-- The schema's primary axis lifted from a bare literal: a Prefix axis takes
-- the pattern, a Set axis the singleton; a Product with no declared schema
-- has no primary axis and the literal is the top.
export
productPrimaryLift : List (String, Param) -> String -> Param
productPrimaryLift [] _ = PProduct []
productPrimaryLift ((name, top) :: _) s = match top
  PPrefix _ => productNorm [(name, canonParam (PPrefix (Some s)))]
  PSet _ => productNorm [(name, PSet (Some [s]))]
  _ => PProduct []

export
lookupAxis : String -> List (String, Param) -> Option Param
lookupAxis _ [] = None
lookupAxis name ((k, v) :: rest) =
  if name == k then Some v else lookupAxis name rest

export
djoin : Param -> Param -> Param
djoin p1 p2 = djoinN (canonParam p1) (canonParam p2)

-- The Prefix join is the longest common prefix of the two concrete parts,
-- spelled as a written pattern: a common prefix that is not one of the
-- operands verbatim takes an explicit trailing wildcard, so the joined
-- pattern is exactly what a signature may write (`"a.com/*" ⊔ "a.com.evil/*"`
-- is `"a.com*"`, never the bare `"a.com"` a signature rejects). An empty
-- common prefix is top.
export
djoinN : Param -> Param -> Param
djoinN PUnit PUnit = PUnit
djoinN (PPrefix None) _ = PPrefix None
djoinN _ (PPrefix None) = PPrefix None
djoinN (PPrefix (Some a)) (PPrefix (Some b)) =
  if a == b then
    PPrefix (Some a)
  else
    let ca = prefixConcrete a
    let cb = prefixConcrete b
    let k = commonPrefixLen ca cb 0
    if k == 0 then PPrefix None else PPrefix (Some (stringSlice 0 k ca ++ "*"))
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
isSubTop (PProduct ax) = allList (a => isSubTop (snd a)) ax
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
drender p = drenderN (canonParam p)

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
prefixConcrete : String -> String
prefixConcrete s =
  let n = stringLength s
  if n > 0 && stringSlice (n - 1) n s == "*" then stringSlice 0 (n - 1) s else s

export
dsub : Param -> Param -> Bool
dsub p1 p2 = dsubN (canonParam p1) (canonParam p2)

export
dsubN : Param -> Param -> Bool
dsubN PUnit PUnit = True
dsubN _ (PPrefix None) = True
dsubN (PPrefix (Some a)) (PPrefix (Some b)) =
  if isPrefixPattern b then
    startsWith (prefixConcrete b) (prefixConcrete a)
  else
    a == b
dsubN (PPrefix None) (PPrefix (Some _)) = False
dsubN _ (PSet None) = True
dsubN (PSet (Some a)) (PSet (Some b)) = subsetStr a b
dsubN (PSet None) (PSet (Some _)) = False
dsubN _ (PProduct []) = True
dsubN (PProduct ax) (PProduct bx) = allList (axisSub ax) bx
dsubN _ _ = False

-- A pattern ends in `*` and admits every element it is a prefix of; any
-- other element is exact and admits only itself: `"/etc/host"` does not
-- admit `/etc/hostname`.
export
isPrefixPattern : String -> Bool
isPrefixPattern s =
  let n = stringLength s
  n > 0 && stringSlice (n - 1) n s == "*"

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
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false))))
(DData Public "Param" () ((variant "PUnit" (ConPos)) (variant "PPrefix" (ConPos (TyApp (TyCon "Option") (TyCon "String")))) (variant "PSet" (ConPos (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))) (variant "PProduct" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))) ())
(DTypeSig true "canonParam" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "canonParam" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "canonParam" ((PCon "PProduct" (PVar "ax"))) (EApp (EVar "productNorm") (EVar "ax")))
(DFunDef false "canonParam" ((PVar "p")) (EVar "p"))
(DTypeSig true "subTopOf" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "subTopOf" ((PCon "PPrefix" PWild)) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PSet" PWild)) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PProduct" (PVar "ax"))) (EApp (EVar "PProduct") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "subTopOf") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax"))))
(DFunDef false "subTopOf" (PWild) (EVar "PUnit"))
(DTypeSig true "productPrimaryLift" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyCon "Param"))))
(DFunDef false "productPrimaryLift" ((PList) PWild) (EApp (EVar "PProduct") (EListLit)))
(DFunDef false "productPrimaryLift" ((PCons (PTuple (PVar "name") (PVar "top")) PWild) (PVar "s")) (EMatch (EVar "top") (arm (PCon "PPrefix" PWild) () (EApp (EVar "productNorm") (EListLit (ETuple (EVar "name") (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))))) (arm (PCon "PSet" PWild) () (EApp (EVar "productNorm") (EListLit (ETuple (EVar "name") (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "s")))))))) (arm PWild () (EApp (EVar "PProduct") (EListLit)))))
(DTypeSig true "lookupAxis" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "lookupAxis" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAxis" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "rest"))))
(DTypeSig true "djoin" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoin" ((PVar "p1") (PVar "p2")) (EApp (EApp (EVar "djoinN") (EApp (EVar "canonParam") (EVar "p1"))) (EApp (EVar "canonParam") (EVar "p2"))))
(DTypeSig true "djoinN" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoinN" ((PCon "PUnit") (PCon "PUnit")) (EVar "PUnit"))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "None")) PWild) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PPrefix" (PCon "None"))) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "a"))) (EBlock (DoLet false false (PVar "ca") (EApp (EVar "prefixConcrete") (EVar "a"))) (DoLet false false (PVar "cb") (EApp (EVar "prefixConcrete") (EVar "b"))) (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "ca")) (EVar "cb")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "k")) (EVar "ca")) (ELit (LString "*"))))))))))
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
(DFunDef false "isSubTop" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EVar "allList") (ELam ((PVar "a")) (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "a"))))) (EVar "ax")))
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
(DFunDef false "drender" ((PVar "p")) (EApp (EVar "drenderN") (EApp (EVar "canonParam") (EVar "p"))))
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
(DTypeSig true "prefixConcrete" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "prefixConcrete" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "*")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig true "dsub" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "dsub" ((PVar "p1") (PVar "p2")) (EApp (EApp (EVar "dsubN") (EApp (EVar "canonParam") (EVar "p1"))) (EApp (EVar "canonParam") (EVar "p2"))))
(DTypeSig true "dsubN" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "dsubN" ((PCon "PUnit") (PCon "PUnit")) (EVar "True"))
(DFunDef false "dsubN" (PWild (PCon "PPrefix" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EIf (EApp (EVar "isPrefixPattern") (EVar "b")) (EApp (EApp (EVar "startsWith") (EApp (EVar "prefixConcrete") (EVar "b"))) (EApp (EVar "prefixConcrete") (EVar "a"))) (EBinOp "==" (EVar "a") (EVar "b"))))
(DFunDef false "dsubN" ((PCon "PPrefix" (PCon "None")) (PCon "PPrefix" (PCon "Some" PWild))) (EVar "False"))
(DFunDef false "dsubN" (PWild (PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "subsetStr") (EVar "a")) (EVar "b")))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "None")) (PCon "PSet" (PCon "Some" PWild))) (EVar "False"))
(DFunDef false "dsubN" (PWild (PCon "PProduct" (PList))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EApp (EApp (EVar "allList") (EApp (EVar "axisSub") (EVar "ax"))) (EVar "bx")))
(DFunDef false "dsubN" (PWild PWild) (EVar "False"))
(DTypeSig true "isPrefixPattern" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isPrefixPattern" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "*")))))))
(DTypeSig true "axisSub" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "Bool"))))
(DFunDef false "axisSub" ((PVar "ax") (PTuple (PVar "name") (PVar "bp"))) (EApp (EApp (EVar "dsubN") (EApp (EApp (EApp (EVar "lookupAxisOrTop") (EVar "name")) (EVar "ax")) (EVar "bp"))) (EVar "bp")))
(DTypeSig true "lookupAxisOrTop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "Param") (TyCon "Param")))))
(DFunDef false "lookupAxisOrTop" ((PVar "name") (PVar "ax") (PVar "bp")) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "subTopOf") (EVar "bp")))))
(DTypeSig true "subsetStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "subsetStr" ((PList) PWild) (EVar "True"))
(DFunDef false "subsetStr" ((PCons (PVar "x") (PVar "xs")) (PVar "b")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "b")) (EApp (EApp (EVar "subsetStr") (EVar "xs")) (EVar "b")) (EVar "False")))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false))))
(DData Public "Param" () ((variant "PUnit" (ConPos)) (variant "PPrefix" (ConPos (TyApp (TyCon "Option") (TyCon "String")))) (variant "PSet" (ConPos (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))) (variant "PProduct" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))) ())
(DTypeSig true "canonParam" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "canonParam" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "canonParam" ((PCon "PProduct" (PVar "ax"))) (EApp (EVar "productNorm") (EVar "ax")))
(DFunDef false "canonParam" ((PVar "p")) (EVar "p"))
(DTypeSig true "subTopOf" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "subTopOf" ((PCon "PPrefix" PWild)) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PSet" PWild)) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PProduct" (PVar "ax"))) (EApp (EVar "PProduct") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "subTopOf") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax"))))
(DFunDef false "subTopOf" (PWild) (EVar "PUnit"))
(DTypeSig true "productPrimaryLift" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyCon "Param"))))
(DFunDef false "productPrimaryLift" ((PList) PWild) (EApp (EVar "PProduct") (EListLit)))
(DFunDef false "productPrimaryLift" ((PCons (PTuple (PVar "name") (PVar "top")) PWild) (PVar "s")) (EMatch (EVar "top") (arm (PCon "PPrefix" PWild) () (EApp (EVar "productNorm") (EListLit (ETuple (EVar "name") (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))))) (arm (PCon "PSet" PWild) () (EApp (EVar "productNorm") (EListLit (ETuple (EVar "name") (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "s")))))))) (arm PWild () (EApp (EVar "PProduct") (EListLit)))))
(DTypeSig true "lookupAxis" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "lookupAxis" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAxis" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "rest"))))
(DTypeSig true "djoin" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoin" ((PVar "p1") (PVar "p2")) (EApp (EApp (EVar "djoinN") (EApp (EVar "canonParam") (EVar "p1"))) (EApp (EVar "canonParam") (EVar "p2"))))
(DTypeSig true "djoinN" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoinN" ((PCon "PUnit") (PCon "PUnit")) (EVar "PUnit"))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "None")) PWild) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PPrefix" (PCon "None"))) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "a"))) (EBlock (DoLet false false (PVar "ca") (EApp (EVar "prefixConcrete") (EVar "a"))) (DoLet false false (PVar "cb") (EApp (EVar "prefixConcrete") (EVar "b"))) (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "ca")) (EVar "cb")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "k")) (EVar "ca")) (ELit (LString "*"))))))))))
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
(DFunDef false "isSubTop" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EVar "allList") (ELam ((PVar "a")) (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "a"))))) (EVar "ax")))
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
(DFunDef false "drender" ((PVar "p")) (EApp (EVar "drenderN") (EApp (EVar "canonParam") (EVar "p"))))
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
(DTypeSig true "prefixConcrete" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "prefixConcrete" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "*")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig true "dsub" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "dsub" ((PVar "p1") (PVar "p2")) (EApp (EApp (EVar "dsubN") (EApp (EVar "canonParam") (EVar "p1"))) (EApp (EVar "canonParam") (EVar "p2"))))
(DTypeSig true "dsubN" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "dsubN" ((PCon "PUnit") (PCon "PUnit")) (EVar "True"))
(DFunDef false "dsubN" (PWild (PCon "PPrefix" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EIf (EApp (EVar "isPrefixPattern") (EVar "b")) (EApp (EApp (EVar "startsWith") (EApp (EVar "prefixConcrete") (EVar "b"))) (EApp (EVar "prefixConcrete") (EVar "a"))) (EBinOp "==" (EVar "a") (EVar "b"))))
(DFunDef false "dsubN" ((PCon "PPrefix" (PCon "None")) (PCon "PPrefix" (PCon "Some" PWild))) (EVar "False"))
(DFunDef false "dsubN" (PWild (PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "subsetStr") (EVar "a")) (EVar "b")))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "None")) (PCon "PSet" (PCon "Some" PWild))) (EVar "False"))
(DFunDef false "dsubN" (PWild (PCon "PProduct" (PList))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EApp (EApp (EVar "allList") (EApp (EVar "axisSub") (EVar "ax"))) (EVar "bx")))
(DFunDef false "dsubN" (PWild PWild) (EVar "False"))
(DTypeSig true "isPrefixPattern" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isPrefixPattern" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "*")))))))
(DTypeSig true "axisSub" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "Bool"))))
(DFunDef false "axisSub" ((PVar "ax") (PTuple (PVar "name") (PVar "bp"))) (EApp (EApp (EVar "dsubN") (EApp (EApp (EApp (EVar "lookupAxisOrTop") (EVar "name")) (EVar "ax")) (EVar "bp"))) (EVar "bp")))
(DTypeSig true "lookupAxisOrTop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "Param") (TyCon "Param")))))
(DFunDef false "lookupAxisOrTop" ((PVar "name") (PVar "ax") (PVar "bp")) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "subTopOf") (EVar "bp")))))
(DTypeSig true "subsetStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "subsetStr" ((PList) PWild) (EVar "True"))
(DFunDef false "subsetStr" ((PCons (PVar "x") (PVar "xs")) (PVar "b")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "b")) (EApp (EApp (EVar "subsetStr") (EVar "xs")) (EVar "b")) (EVar "False")))
