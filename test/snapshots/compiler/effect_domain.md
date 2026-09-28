# META
source_lines=391
stages=DESUGAR,MARK
# SOURCE
-- Concrete authority domains: the lattice each effect label's parameter is
-- drawn from. Domain operations do not depend on inference state, syntax, or
-- dictionary selection; atoms and rows are built over them in `effect_rows`.

import support.util.{
  listLen, filterList, joinWith, sortUniqS, startsWith, contains, allList,
  anyList, reverseL
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

-- The element a value denotes once an unknown suffix is appended to it. A
-- pattern already admits every extension; an exact element becomes the
-- pattern it begins; a Set member becomes an unknown member, the top. In a
-- Product only the primary axis, the one a string lifts into, is extended.
export
extendParam : Param -> Param -> Param
extendParam top p = match canonParam p
  PPrefix (Some s) =>
    if isPrefixPattern s then PPrefix (Some s) else PPrefix (Some (s ++ "*"))
  PProduct ax => match top
    PProduct ((name, _) :: _) => productNorm (map (extendAxis name) ax)
    _ => PProduct []
  q => subTopOf q

extendAxis : String -> (String, Param) -> (String, Param)
extendAxis primary (name, p) =
  if name == primary then (name, extendParam (subTopOf p) p) else (name, p)

-- The element a value denotes once a known suffix is appended: an exact
-- element grows by the suffix, a pattern already admits it, and a Set member
-- becomes an unknown member.
export
appendParam : Param -> String -> Param -> Param
appendParam top suffix p = match canonParam p
  PPrefix (Some s) =>
    if isPrefixPattern s then
      PPrefix (Some s)
    else
      canonParam (PPrefix (Some (s ++ suffix)))
  PProduct ax => match top
    PProduct ((name, _) :: _) => productNorm (map (appendAxis suffix name) ax)
    _ => PProduct []
  q => subTopOf q

appendAxis : String -> String -> (String, Param) -> (String, Param)
appendAxis suffix primary (name, p) =
  if name == primary then
    (name, appendParam (subTopOf p) suffix p)
  else
    (name, p)

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
djoinN p q = joinCapped setCardCap p q

-- The join with a Set union that saturates to top past [cap] members.
-- Inference joins at `setCardCap`; the check of a written bound joins with no
-- cap, so a union too large to keep is seen and refused instead of widened.
joinCapped : Int -> Param -> Param -> Param
joinCapped _ PUnit PUnit = PUnit
joinCapped _ (PPrefix None) _ = PPrefix None
joinCapped _ _ (PPrefix None) = PPrefix None
joinCapped _ (PPrefix (Some a)) (PPrefix (Some b)) =
  if a == b then
    PPrefix (Some a)
  else
    let ca = prefixConcrete a
    let cb = prefixConcrete b
    let k = commonPrefixLen ca cb 0
    if k == 0 then PPrefix None else PPrefix (Some (stringSlice 0 k ca ++ "*"))
joinCapped _ (PSet None) _ = PSet None
joinCapped _ _ (PSet None) = PSet None
joinCapped cap (PSet (Some a)) (PSet (Some b)) =
  let u = sortUniqS (a ++ b)
  if listLen u > cap then PSet None else PSet (Some u)
joinCapped cap (PProduct ax) (PProduct bx) =
  productNorm (map (joinAxisCapped cap ax bx) (axisUnion ax bx))
joinCapped _ p _ = p

-- The elements a join of constants denotes, kept as an antichain: no member
-- covers another. Two members are merged only where their join adds nothing
-- neither admits, which holds for Set members and for Products that differ
-- in one Set axis; Prefix patterns and other Products stay separate, so
-- `"a.com/*"` beside `"b.com/*"` admits those two hosts and nothing else.
-- Past `setCardCap` members the set is folded by the domain join, which
-- covers every member and bounds how far a fixpoint can grow; a written
-- bound past it is refused (`writtenSetProblem`). Members are ordered by their
-- rendering.
export
dantichain : List Param -> List Param
dantichain ps =
  let kept = dmaximal ps
  if listLen kept > setCardCap then
    [fold djoinN (headParam kept) kept]
  else
    kept

-- The antichain before the cap. Its inputs are merged in the order of their
-- rendering, so the same elements written in any order give the same set.
export
dmaximal : List Param -> List Param
dmaximal ps = maximalWith setCardCap ps

maximalWith : Int -> List Param -> List Param
maximalWith cap ps =
  sortParams
    (fold
      (acc p => insertMaximal cap p acc)
      []
      (sortParams (map canonParam ps)))

-- Why a written bound cannot be kept as written: more than `setCardCap`
-- elements of one label, or Set members that merge into a set larger than
-- that. Inference would fold either into a wider element, so a bound, which
-- must never widen, is refused instead. The members merge with no cap here,
-- so a union that inference would saturate to top is seen.
export
writtenSetProblem : List Param -> Option String
writtenSetProblem ps =
  let merged = maximalWith noSetCap ps
  let n = listLen merged
  if n > setCardCap then
    Some
      "a bound admits at most \{intToString setCardCap} elements of one label, and this one writes \{intToString n}; write a pattern that covers several of them"
  else match filterList (> setCardCap) (map largestSet merged)
    big :: _ =>
      Some
        "a set holds at most \{intToString setCardCap} members, and these elements merge into one of \{intToString big}"
    [] => None

noSetCap : Int
noSetCap = 1073741823

largestSet : Param -> Int
largestSet (PSet (Some xs)) = listLen xs
largestSet (PProduct ax) = fold (acc a => max acc (largestSet (snd a))) 0 ax
largestSet _ = 0

headParam : List Param -> Param
headParam (p :: _) = p
headParam [] = PUnit

insertMaximal : Int -> Param -> List Param -> List Param
insertMaximal cap p acc =
  if anyList (q => dsubN p q) acc then
    acc
  else
    let rest = filterList (q => not (dsubN q p)) acc
    match exactMerge cap p rest []
      Some (merged, others) => insertMaximal cap merged others
      None => p :: rest

-- The first member `p` merges with exactly, and the other members.
exactMerge : Int ->
  Param ->
  List Param ->
  List Param ->
  Option (Param, List Param)
exactMerge _ _ [] _ = None
exactMerge cap p (q :: qs) seen =
  if joinIsExact p q then
    Some (joinCapped cap p q, reverseL seen ++ qs)
  else
    exactMerge cap p qs (q :: seen)

joinIsExact : Param -> Param -> Bool
joinIsExact PUnit PUnit = True
joinIsExact (PSet _) (PSet _) = True
joinIsExact (PProduct ax) (PProduct bx) =
  match filterList (n => not (axisEq n ax bx)) (axisUnion ax bx)
    [name] => match (lookupAxis name ax, lookupAxis name bx)
      (Some (PSet (Some _)), Some (PSet (Some _))) => True
      _ => False
    _ => False
joinIsExact _ _ = False

axisEq : String -> List (String, Param) -> List (String, Param) -> Bool
axisEq name ax bx = match (lookupAxis name ax, lookupAxis name bx)
  (Some a, Some b) => dsubN a b && dsubN b a
  (None, None) => True
  _ => False

sortParams : List Param -> List Param
sortParams [] = []
sortParams (p :: ps) = insertParam p (sortParams ps)

insertParam : Param -> List Param -> List Param
insertParam p [] = [p]
insertParam p (q :: qs) = match stringCompare (drenderN p) (drenderN q)
  Gt => q :: insertParam p qs
  _ => p :: q :: qs

export
joinAxis : List (String, Param) ->
  List (String, Param) ->
  String ->
  (String, Param)
joinAxis ax bx name = joinAxisCapped setCardCap ax bx name

joinAxisCapped : Int ->
  List (String, Param) ->
  List (String, Param) ->
  String ->
  (String, Param)
joinAxisCapped cap ax bx name = match (lookupAxis name ax, lookupAxis name bx)
  (Some pa, Some pb) => (name, joinCapped cap pa pb)
  (Some pa, None) => (name, joinCapped cap pa (subTopOf pa))
  (None, Some pb) => (name, joinCapped cap (subTopOf pb) pb)
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
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false) (mem "anyList" false) (mem "reverseL" false))))
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
(DTypeSig true "extendParam" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "extendParam" ((PVar "top") (PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (ELit (LString "*"))))))) (arm (PCon "PProduct" (PVar "ax")) () (EMatch (EVar "top") (arm (PCon "PProduct" (PCons (PTuple (PVar "name") PWild) PWild)) () (EApp (EVar "productNorm") (EApp (EApp (EVar "map") (EApp (EVar "extendAxis") (EVar "name"))) (EVar "ax")))) (arm PWild () (EApp (EVar "PProduct") (EListLit))))) (arm (PVar "q") () (EApp (EVar "subTopOf") (EVar "q")))))
(DTypeSig false "extendAxis" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "extendAxis" ((PVar "primary") (PTuple (PVar "name") (PVar "p"))) (EIf (EBinOp "==" (EVar "name") (EVar "primary")) (ETuple (EVar "name") (EApp (EApp (EVar "extendParam") (EApp (EVar "subTopOf") (EVar "p"))) (EVar "p"))) (ETuple (EVar "name") (EVar "p"))))
(DTypeSig true "appendParam" (TyFun (TyCon "Param") (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyCon "Param")))))
(DFunDef false "appendParam" ((PVar "top") (PVar "suffix") (PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (EVar "suffix"))))))) (arm (PCon "PProduct" (PVar "ax")) () (EMatch (EVar "top") (arm (PCon "PProduct" (PCons (PTuple (PVar "name") PWild) PWild)) () (EApp (EVar "productNorm") (EApp (EApp (EVar "map") (EApp (EApp (EVar "appendAxis") (EVar "suffix")) (EVar "name"))) (EVar "ax")))) (arm PWild () (EApp (EVar "PProduct") (EListLit))))) (arm (PVar "q") () (EApp (EVar "subTopOf") (EVar "q")))))
(DTypeSig false "appendAxis" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "appendAxis" ((PVar "suffix") (PVar "primary") (PTuple (PVar "name") (PVar "p"))) (EIf (EBinOp "==" (EVar "name") (EVar "primary")) (ETuple (EVar "name") (EApp (EApp (EApp (EVar "appendParam") (EApp (EVar "subTopOf") (EVar "p"))) (EVar "suffix")) (EVar "p"))) (ETuple (EVar "name") (EVar "p"))))
(DTypeSig true "lookupAxis" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "lookupAxis" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAxis" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "rest"))))
(DTypeSig true "djoin" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoin" ((PVar "p1") (PVar "p2")) (EApp (EApp (EVar "djoinN") (EApp (EVar "canonParam") (EVar "p1"))) (EApp (EVar "canonParam") (EVar "p2"))))
(DTypeSig true "djoinN" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoinN" ((PVar "p") (PVar "q")) (EApp (EApp (EApp (EVar "joinCapped") (EVar "setCardCap")) (EVar "p")) (EVar "q")))
(DTypeSig false "joinCapped" (TyFun (TyCon "Int") (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param")))))
(DFunDef false "joinCapped" (PWild (PCon "PUnit") (PCon "PUnit")) (EVar "PUnit"))
(DFunDef false "joinCapped" (PWild (PCon "PPrefix" (PCon "None")) PWild) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "joinCapped" (PWild PWild (PCon "PPrefix" (PCon "None"))) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "joinCapped" (PWild (PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "a"))) (EBlock (DoLet false false (PVar "ca") (EApp (EVar "prefixConcrete") (EVar "a"))) (DoLet false false (PVar "cb") (EApp (EVar "prefixConcrete") (EVar "b"))) (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "ca")) (EVar "cb")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "k")) (EVar "ca")) (ELit (LString "*"))))))))))
(DFunDef false "joinCapped" (PWild (PCon "PSet" (PCon "None")) PWild) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "joinCapped" (PWild PWild (PCon "PSet" (PCon "None"))) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "joinCapped" ((PVar "cap") (PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EBlock (DoLet false false (PVar "u") (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "a") (EVar "b")))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "u")) (EVar "cap")) (EApp (EVar "PSet") (EVar "None")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "u")))))))
(DFunDef false "joinCapped" ((PVar "cap") (PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EApp (EVar "productNorm") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "joinAxisCapped") (EVar "cap")) (EVar "ax")) (EVar "bx"))) (EApp (EApp (EVar "axisUnion") (EVar "ax")) (EVar "bx")))))
(DFunDef false "joinCapped" (PWild (PVar "p") PWild) (EVar "p"))
(DTypeSig true "dantichain" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "dantichain" ((PVar "ps")) (EBlock (DoLet false false (PVar "kept") (EApp (EVar "dmaximal") (EVar "ps"))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "kept")) (EVar "setCardCap")) (EListLit (EApp (EApp (EApp (EVar "fold") (EVar "djoinN")) (EApp (EVar "headParam") (EVar "kept"))) (EVar "kept"))) (EVar "kept")))))
(DTypeSig true "dmaximal" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "dmaximal" ((PVar "ps")) (EApp (EApp (EVar "maximalWith") (EVar "setCardCap")) (EVar "ps")))
(DTypeSig false "maximalWith" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "maximalWith" ((PVar "cap") (PVar "ps")) (EApp (EVar "sortParams") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EApp (EVar "insertMaximal") (EVar "cap")) (EVar "p")) (EVar "acc")))) (EListLit)) (EApp (EVar "sortParams") (EApp (EApp (EVar "map") (EVar "canonParam")) (EVar "ps"))))))
(DTypeSig true "writtenSetProblem" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "writtenSetProblem" ((PVar "ps")) (EBlock (DoLet false false (PVar "merged") (EApp (EApp (EVar "maximalWith") (EVar "noSetCap")) (EVar "ps"))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "merged"))) (DoExpr (EIf (EBinOp ">" (EVar "n") (EVar "setCardCap")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a bound admits at most ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "setCardCap")))) (ELit (LString " elements of one label, and this one writes "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "; write a pattern that covers several of them")))) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (EVar "setCardCap")))) (EApp (EApp (EVar "map") (EVar "largestSet")) (EVar "merged"))) (arm (PCons (PVar "big") PWild) () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a set holds at most ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "setCardCap")))) (ELit (LString " members, and these elements merge into one of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "big")))) (ELit (LString ""))))) (arm (PList) () (EVar "None")))))))
(DTypeSig false "noSetCap" (TyCon "Int"))
(DFunDef false "noSetCap" () (ELit (LInt 1073741823)))
(DTypeSig false "largestSet" (TyFun (TyCon "Param") (TyCon "Int")))
(DFunDef false "largestSet" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EApp (EVar "listLen") (EVar "xs")))
(DFunDef false "largestSet" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "a")) (EApp (EApp (EVar "max") (EVar "acc")) (EApp (EVar "largestSet") (EApp (EVar "snd") (EVar "a")))))) (ELit (LInt 0))) (EVar "ax")))
(DFunDef false "largestSet" (PWild) (ELit (LInt 0)))
(DTypeSig false "headParam" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Param")))
(DFunDef false "headParam" ((PCons (PVar "p") PWild)) (EVar "p"))
(DFunDef false "headParam" ((PList)) (EVar "PUnit"))
(DTypeSig false "insertMaximal" (TyFun (TyCon "Int") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))))
(DFunDef false "insertMaximal" ((PVar "cap") (PVar "p") (PVar "acc")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "q")) (EApp (EApp (EVar "dsubN") (EVar "p")) (EVar "q")))) (EVar "acc")) (EVar "acc") (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "filterList") (ELam ((PVar "q")) (EApp (EVar "not") (EApp (EApp (EVar "dsubN") (EVar "q")) (EVar "p"))))) (EVar "acc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "exactMerge") (EVar "cap")) (EVar "p")) (EVar "rest")) (EListLit)) (arm (PCon "Some" (PTuple (PVar "merged") (PVar "others"))) () (EApp (EApp (EApp (EVar "insertMaximal") (EVar "cap")) (EVar "merged")) (EVar "others"))) (arm (PCon "None") () (EBinOp "::" (EVar "p") (EVar "rest"))))))))
(DTypeSig false "exactMerge" (TyFun (TyCon "Int") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "Option") (TyTuple (TyCon "Param") (TyApp (TyCon "List") (TyCon "Param")))))))))
(DFunDef false "exactMerge" (PWild PWild (PList) PWild) (EVar "None"))
(DFunDef false "exactMerge" ((PVar "cap") (PVar "p") (PCons (PVar "q") (PVar "qs")) (PVar "seen")) (EIf (EApp (EApp (EVar "joinIsExact") (EVar "p")) (EVar "q")) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EVar "joinCapped") (EVar "cap")) (EVar "p")) (EVar "q")) (EBinOp "++" (EApp (EVar "reverseL") (EVar "seen")) (EVar "qs")))) (EApp (EApp (EApp (EApp (EVar "exactMerge") (EVar "cap")) (EVar "p")) (EVar "qs")) (EBinOp "::" (EVar "q") (EVar "seen")))))
(DTypeSig false "joinIsExact" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "joinIsExact" ((PCon "PUnit") (PCon "PUnit")) (EVar "True"))
(DFunDef false "joinIsExact" ((PCon "PSet" PWild) (PCon "PSet" PWild)) (EVar "True"))
(DFunDef false "joinIsExact" ((PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "axisEq") (EVar "n")) (EVar "ax")) (EVar "bx"))))) (EApp (EApp (EVar "axisUnion") (EVar "ax")) (EVar "bx"))) (arm (PList (PVar "name")) () (EMatch (ETuple (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "bx"))) (arm (PTuple (PCon "Some" (PCon "PSet" (PCon "Some" PWild))) (PCon "Some" (PCon "PSet" (PCon "Some" PWild)))) () (EVar "True")) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DFunDef false "joinIsExact" (PWild PWild) (EVar "False"))
(DTypeSig false "axisEq" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Bool")))))
(DFunDef false "axisEq" ((PVar "name") (PVar "ax") (PVar "bx")) (EMatch (ETuple (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "bx"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EBinOp "&&" (EApp (EApp (EVar "dsubN") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "dsubN") (EVar "b")) (EVar "a")))) (arm (PTuple (PCon "None") (PCon "None")) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "sortParams" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "sortParams" ((PList)) (EListLit))
(DFunDef false "sortParams" ((PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EVar "insertParam") (EVar "p")) (EApp (EVar "sortParams") (EVar "ps"))))
(DTypeSig false "insertParam" (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "insertParam" ((PVar "p") (PList)) (EListLit (EVar "p")))
(DFunDef false "insertParam" ((PVar "p") (PCons (PVar "q") (PVar "qs"))) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "drenderN") (EVar "p"))) (EApp (EVar "drenderN") (EVar "q"))) (arm (PCon "Gt") () (EBinOp "::" (EVar "q") (EApp (EApp (EVar "insertParam") (EVar "p")) (EVar "qs")))) (arm PWild () (EBinOp "::" (EVar "p") (EBinOp "::" (EVar "q") (EVar "qs"))))))
(DTypeSig true "joinAxis" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "joinAxis" ((PVar "ax") (PVar "bx") (PVar "name")) (EApp (EApp (EApp (EApp (EVar "joinAxisCapped") (EVar "setCardCap")) (EVar "ax")) (EVar "bx")) (EVar "name")))
(DTypeSig false "joinAxisCapped" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Param")))))))
(DFunDef false "joinAxisCapped" ((PVar "cap") (PVar "ax") (PVar "bx") (PVar "name")) (EMatch (ETuple (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "bx"))) (arm (PTuple (PCon "Some" (PVar "pa")) (PCon "Some" (PVar "pb"))) () (ETuple (EVar "name") (EApp (EApp (EApp (EVar "joinCapped") (EVar "cap")) (EVar "pa")) (EVar "pb")))) (arm (PTuple (PCon "Some" (PVar "pa")) (PCon "None")) () (ETuple (EVar "name") (EApp (EApp (EApp (EVar "joinCapped") (EVar "cap")) (EVar "pa")) (EApp (EVar "subTopOf") (EVar "pa"))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "pb"))) () (ETuple (EVar "name") (EApp (EApp (EApp (EVar "joinCapped") (EVar "cap")) (EApp (EVar "subTopOf") (EVar "pb"))) (EVar "pb")))) (arm (PTuple (PCon "None") (PCon "None")) () (ETuple (EVar "name") (EVar "PUnit")))))
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
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false) (mem "anyList" false) (mem "reverseL" false))))
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
(DTypeSig true "extendParam" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "extendParam" ((PVar "top") (PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (ELit (LString "*"))))))) (arm (PCon "PProduct" (PVar "ax")) () (EMatch (EVar "top") (arm (PCon "PProduct" (PCons (PTuple (PVar "name") PWild) PWild)) () (EApp (EVar "productNorm") (EApp (EApp (EMethodRef "map") (EApp (EVar "extendAxis") (EVar "name"))) (EVar "ax")))) (arm PWild () (EApp (EVar "PProduct") (EListLit))))) (arm (PVar "q") () (EApp (EVar "subTopOf") (EVar "q")))))
(DTypeSig false "extendAxis" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "extendAxis" ((PVar "primary") (PTuple (PVar "name") (PVar "p"))) (EIf (EBinOp "==" (EVar "name") (EVar "primary")) (ETuple (EVar "name") (EApp (EApp (EVar "extendParam") (EApp (EVar "subTopOf") (EVar "p"))) (EVar "p"))) (ETuple (EVar "name") (EVar "p"))))
(DTypeSig true "appendParam" (TyFun (TyCon "Param") (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyCon "Param")))))
(DFunDef false "appendParam" ((PVar "top") (PVar "suffix") (PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (EVar "suffix"))))))) (arm (PCon "PProduct" (PVar "ax")) () (EMatch (EVar "top") (arm (PCon "PProduct" (PCons (PTuple (PVar "name") PWild) PWild)) () (EApp (EVar "productNorm") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "appendAxis") (EVar "suffix")) (EVar "name"))) (EVar "ax")))) (arm PWild () (EApp (EVar "PProduct") (EListLit))))) (arm (PVar "q") () (EApp (EVar "subTopOf") (EVar "q")))))
(DTypeSig false "appendAxis" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "appendAxis" ((PVar "suffix") (PVar "primary") (PTuple (PVar "name") (PVar "p"))) (EIf (EBinOp "==" (EVar "name") (EVar "primary")) (ETuple (EVar "name") (EApp (EApp (EApp (EVar "appendParam") (EApp (EVar "subTopOf") (EVar "p"))) (EVar "suffix")) (EVar "p"))) (ETuple (EVar "name") (EVar "p"))))
(DTypeSig true "lookupAxis" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "lookupAxis" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAxis" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "rest"))))
(DTypeSig true "djoin" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoin" ((PVar "p1") (PVar "p2")) (EApp (EApp (EVar "djoinN") (EApp (EVar "canonParam") (EVar "p1"))) (EApp (EVar "canonParam") (EVar "p2"))))
(DTypeSig true "djoinN" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "djoinN" ((PVar "p") (PVar "q")) (EApp (EApp (EApp (EVar "joinCapped") (EVar "setCardCap")) (EVar "p")) (EVar "q")))
(DTypeSig false "joinCapped" (TyFun (TyCon "Int") (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param")))))
(DFunDef false "joinCapped" (PWild (PCon "PUnit") (PCon "PUnit")) (EVar "PUnit"))
(DFunDef false "joinCapped" (PWild (PCon "PPrefix" (PCon "None")) PWild) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "joinCapped" (PWild PWild (PCon "PPrefix" (PCon "None"))) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "joinCapped" (PWild (PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "a"))) (EBlock (DoLet false false (PVar "ca") (EApp (EVar "prefixConcrete") (EVar "a"))) (DoLet false false (PVar "cb") (EApp (EVar "prefixConcrete") (EVar "b"))) (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "ca")) (EVar "cb")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "k")) (EVar "ca")) (ELit (LString "*"))))))))))
(DFunDef false "joinCapped" (PWild (PCon "PSet" (PCon "None")) PWild) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "joinCapped" (PWild PWild (PCon "PSet" (PCon "None"))) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "joinCapped" ((PVar "cap") (PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EBlock (DoLet false false (PVar "u") (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "a") (EVar "b")))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "u")) (EVar "cap")) (EApp (EVar "PSet") (EVar "None")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "u")))))))
(DFunDef false "joinCapped" ((PVar "cap") (PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EApp (EVar "productNorm") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "joinAxisCapped") (EVar "cap")) (EVar "ax")) (EVar "bx"))) (EApp (EApp (EVar "axisUnion") (EVar "ax")) (EVar "bx")))))
(DFunDef false "joinCapped" (PWild (PVar "p") PWild) (EVar "p"))
(DTypeSig true "dantichain" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "dantichain" ((PVar "ps")) (EBlock (DoLet false false (PVar "kept") (EApp (EVar "dmaximal") (EVar "ps"))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "kept")) (EVar "setCardCap")) (EListLit (EApp (EApp (EApp (EMethodRef "fold") (EVar "djoinN")) (EApp (EVar "headParam") (EVar "kept"))) (EVar "kept"))) (EVar "kept")))))
(DTypeSig true "dmaximal" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "dmaximal" ((PVar "ps")) (EApp (EApp (EVar "maximalWith") (EVar "setCardCap")) (EVar "ps")))
(DTypeSig false "maximalWith" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "maximalWith" ((PVar "cap") (PVar "ps")) (EApp (EVar "sortParams") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EApp (EVar "insertMaximal") (EVar "cap")) (EVar "p")) (EVar "acc")))) (EListLit)) (EApp (EVar "sortParams") (EApp (EApp (EMethodRef "map") (EVar "canonParam")) (EVar "ps"))))))
(DTypeSig true "writtenSetProblem" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "writtenSetProblem" ((PVar "ps")) (EBlock (DoLet false false (PVar "merged") (EApp (EApp (EVar "maximalWith") (EVar "noSetCap")) (EVar "ps"))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "merged"))) (DoExpr (EIf (EBinOp ">" (EVar "n") (EVar "setCardCap")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a bound admits at most ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "setCardCap")))) (ELit (LString " elements of one label, and this one writes "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "; write a pattern that covers several of them")))) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (EVar "setCardCap")))) (EApp (EApp (EMethodRef "map") (EVar "largestSet")) (EVar "merged"))) (arm (PCons (PVar "big") PWild) () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a set holds at most ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "setCardCap")))) (ELit (LString " members, and these elements merge into one of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "big")))) (ELit (LString ""))))) (arm (PList) () (EVar "None")))))))
(DTypeSig false "noSetCap" (TyCon "Int"))
(DFunDef false "noSetCap" () (ELit (LInt 1073741823)))
(DTypeSig false "largestSet" (TyFun (TyCon "Param") (TyCon "Int")))
(DFunDef false "largestSet" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EApp (EVar "listLen") (EVar "xs")))
(DFunDef false "largestSet" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "a")) (EApp (EApp (EMethodRef "max") (EVar "acc")) (EApp (EVar "largestSet") (EApp (EVar "snd") (EVar "a")))))) (ELit (LInt 0))) (EVar "ax")))
(DFunDef false "largestSet" (PWild) (ELit (LInt 0)))
(DTypeSig false "headParam" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Param")))
(DFunDef false "headParam" ((PCons (PVar "p") PWild)) (EVar "p"))
(DFunDef false "headParam" ((PList)) (EVar "PUnit"))
(DTypeSig false "insertMaximal" (TyFun (TyCon "Int") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))))
(DFunDef false "insertMaximal" ((PVar "cap") (PVar "p") (PVar "acc")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "q")) (EApp (EApp (EVar "dsubN") (EVar "p")) (EVar "q")))) (EVar "acc")) (EVar "acc") (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "filterList") (ELam ((PVar "q")) (EApp (EVar "not") (EApp (EApp (EVar "dsubN") (EVar "q")) (EVar "p"))))) (EVar "acc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "exactMerge") (EVar "cap")) (EVar "p")) (EVar "rest")) (EListLit)) (arm (PCon "Some" (PTuple (PVar "merged") (PVar "others"))) () (EApp (EApp (EApp (EVar "insertMaximal") (EVar "cap")) (EVar "merged")) (EVar "others"))) (arm (PCon "None") () (EBinOp "::" (EVar "p") (EVar "rest"))))))))
(DTypeSig false "exactMerge" (TyFun (TyCon "Int") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "Option") (TyTuple (TyCon "Param") (TyApp (TyCon "List") (TyCon "Param")))))))))
(DFunDef false "exactMerge" (PWild PWild (PList) PWild) (EVar "None"))
(DFunDef false "exactMerge" ((PVar "cap") (PVar "p") (PCons (PVar "q") (PVar "qs")) (PVar "seen")) (EIf (EApp (EApp (EVar "joinIsExact") (EVar "p")) (EVar "q")) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EVar "joinCapped") (EVar "cap")) (EVar "p")) (EVar "q")) (EBinOp "++" (EApp (EVar "reverseL") (EVar "seen")) (EVar "qs")))) (EApp (EApp (EApp (EApp (EVar "exactMerge") (EVar "cap")) (EVar "p")) (EVar "qs")) (EBinOp "::" (EVar "q") (EVar "seen")))))
(DTypeSig false "joinIsExact" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "joinIsExact" ((PCon "PUnit") (PCon "PUnit")) (EVar "True"))
(DFunDef false "joinIsExact" ((PCon "PSet" PWild) (PCon "PSet" PWild)) (EVar "True"))
(DFunDef false "joinIsExact" ((PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "axisEq") (EVar "n")) (EVar "ax")) (EVar "bx"))))) (EApp (EApp (EVar "axisUnion") (EVar "ax")) (EVar "bx"))) (arm (PList (PVar "name")) () (EMatch (ETuple (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "bx"))) (arm (PTuple (PCon "Some" (PCon "PSet" (PCon "Some" PWild))) (PCon "Some" (PCon "PSet" (PCon "Some" PWild)))) () (EVar "True")) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DFunDef false "joinIsExact" (PWild PWild) (EVar "False"))
(DTypeSig false "axisEq" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Bool")))))
(DFunDef false "axisEq" ((PVar "name") (PVar "ax") (PVar "bx")) (EMatch (ETuple (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "bx"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EBinOp "&&" (EApp (EApp (EVar "dsubN") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "dsubN") (EVar "b")) (EVar "a")))) (arm (PTuple (PCon "None") (PCon "None")) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "sortParams" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "sortParams" ((PList)) (EListLit))
(DFunDef false "sortParams" ((PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EVar "insertParam") (EVar "p")) (EApp (EVar "sortParams") (EVar "ps"))))
(DTypeSig false "insertParam" (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "insertParam" ((PVar "p") (PList)) (EListLit (EVar "p")))
(DFunDef false "insertParam" ((PVar "p") (PCons (PVar "q") (PVar "qs"))) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "drenderN") (EVar "p"))) (EApp (EVar "drenderN") (EVar "q"))) (arm (PCon "Gt") () (EBinOp "::" (EVar "q") (EApp (EApp (EVar "insertParam") (EVar "p")) (EVar "qs")))) (arm PWild () (EBinOp "::" (EVar "p") (EBinOp "::" (EVar "q") (EVar "qs"))))))
(DTypeSig true "joinAxis" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "joinAxis" ((PVar "ax") (PVar "bx") (PVar "name")) (EApp (EApp (EApp (EApp (EVar "joinAxisCapped") (EVar "setCardCap")) (EVar "ax")) (EVar "bx")) (EVar "name")))
(DTypeSig false "joinAxisCapped" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Param")))))))
(DFunDef false "joinAxisCapped" ((PVar "cap") (PVar "ax") (PVar "bx") (PVar "name")) (EMatch (ETuple (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "bx"))) (arm (PTuple (PCon "Some" (PVar "pa")) (PCon "Some" (PVar "pb"))) () (ETuple (EVar "name") (EApp (EApp (EApp (EVar "joinCapped") (EVar "cap")) (EVar "pa")) (EVar "pb")))) (arm (PTuple (PCon "Some" (PVar "pa")) (PCon "None")) () (ETuple (EVar "name") (EApp (EApp (EApp (EVar "joinCapped") (EVar "cap")) (EVar "pa")) (EApp (EVar "subTopOf") (EVar "pa"))))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "pb"))) () (ETuple (EVar "name") (EApp (EApp (EApp (EVar "joinCapped") (EVar "cap")) (EApp (EVar "subTopOf") (EVar "pb"))) (EVar "pb")))) (arm (PTuple (PCon "None") (PCon "None")) () (ETuple (EVar "name") (EVar "PUnit")))))
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
