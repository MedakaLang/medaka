# META
source_lines=553
stages=DESUGAR,MARK
# SOURCE
-- Concrete authority domains: the lattice each effect label's parameter is
-- drawn from. Domain operations do not depend on inference state, syntax, or
-- dictionary selection; atoms and rows are built over them in `effect_rows`.

import support.util.{
  listLen, filterList, joinWith, sortUniqS, startsWith, contains, allList,
  anyList, reverseL, lenKey
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

-- The elements a join of constants denotes, in one canonical form that
-- depends only on what they admit, never on the order they were written or
-- joined in:
--   * Set members are one set, their union: the Set join is exact.
--   * Prefix patterns are the maximal ones: a pattern another covers is
--     dropped, and the rest stay separate, so `"a.com/*"` beside
--     `"b.com/*"` admits those two hosts and nothing else.
--   * Products are regrouped along one Set axis, the last by name: every
--     other Set axis is split into single members, tuples equal on all the
--     other axes share one set of that axis's members, and a member another
--     tuple covers is dropped. `Host="a.com/*" Method={"GET"}` beside the
--     same host with `{"POST"}` is one tuple with both; beside
--     `Host="b.com/*"` it stays two, since their pointwise join would admit
--     POST to a.com.
-- Nothing is folded wider: a set of any size stays exact. Only a written
-- bound is held to `setCardCap` (`writtenSetProblem`), and only a value's
-- abstraction is widened past it (`authWidenValue`).
export
dantichain : List Param -> List Param
dantichain ps =
  let cs = map canonParam ps
  if anyList isSubTop cs then
    [subTopOf (headParam cs)]
  else match cs
    (PSet _) :: _ => [PSet (Some (sortUniqS (flatMap setMembers cs)))]
    (PPrefix _) :: _ => sortParams (maximalPrefixes cs)
    (PProduct _) :: _ => sortParams (canonProducts cs)
    [] => []
    _ => sortParams (maximalOf cs)

-- Why a written bound cannot be kept as written: more than `setCardCap`
-- elements of one label as written (less any another covers), or a set of
-- more than `setCardCap` members.
export
writtenSetProblem : List Param -> Option String
writtenSetProblem ps =
  let cs = map canonParam ps
  let written = match cs
    (PSet _) :: _ => dantichain cs
    _ => maximalOf cs
  let n = listLen written
  let bigs =
    filterList (> setCardCap) (map largestSet (written ++ dantichain cs))
  if n > setCardCap then
    Some
      "a bound admits at most \{intToString setCardCap} elements of one label, and this one writes \{intToString n}; write a pattern that covers several of them"
  else match bigs
    big :: _ =>
      Some
        "a set holds at most \{intToString setCardCap} members, and this one has \{intToString big}"
    [] => None

-- `p` lies within the set [qs]: some element covers it, or, for a Product,
-- each of its singletons is covered by some element, so a tuple the elements
-- cover only together is within them.
export
dsubAny : Param -> List Param -> Bool
dsubAny p qs =
  let cp = canonParam p
  let cqs = map canonParam qs
  anyList (dsubN cp) cqs
    || (match cp
      PProduct _ => allList (s => anyList (dsubN s) cqs) (singletonsOf cp)
      _ => False)

setMembers : Param -> List String
setMembers (PSet (Some xs)) = xs
setMembers _ = []

largestSet : Param -> Int
largestSet (PSet (Some xs)) = listLen xs
largestSet (PProduct ax) = fold (acc a => max acc (largestSet (snd a))) 0 ax
largestSet _ = 0

headParam : List Param -> Param
headParam (p :: _) = p
headParam [] = PUnit

-- The elements no other element covers; of two that cover each other, one.
maximalOf : List Param -> List Param
maximalOf ps = fold (acc p => keepMaximal p acc) [] ps

keepMaximal : Param -> List Param -> List Param
keepMaximal p acc =
  if anyList (q => dsubN p q) acc then
    acc
  else
    p :: filterList (q => not (dsubN q p)) acc

-- The maximal Prefix patterns, by one sweep in order of concrete part. An
-- element that covers another has a concrete part that is a prefix of the
-- other's, so it comes first in that order (a pattern before an exact
-- element of the same part), and stays on the stack of open patterns until
-- an element outside it is reached.
maximalPrefixes : List Param -> List Param
maximalPrefixes ps =
  prefixSweep (sortByKey prefixOrder (map prefixEntry ps)) [] None []

data PrefixEntry = PrefixEntry String Bool Param

prefixEntry : Param -> PrefixEntry
prefixEntry (p@(PPrefix (Some s))) =
  if isPrefixPattern s then
    PrefixEntry (prefixConcrete s) True p
  else
    PrefixEntry s False p
prefixEntry p = PrefixEntry "" True p

prefixOrder : PrefixEntry -> PrefixEntry -> Bool
prefixOrder (PrefixEntry a pa _) (PrefixEntry b pb _) = match stringCompare a b
  Lt => True
  Gt => False
  Eq => pa || not pb

prefixSweep : List PrefixEntry ->
  List String ->
  Option String ->
  List Param ->
  List Param
prefixSweep [] _ _ kept = kept
prefixSweep ((PrefixEntry c pat p) :: rest) open lastExact kept =
  let still = dropWhileNotPrefix c open
  if isNonEmpty still || not pat && lastExact == Some c then
    prefixSweep rest still lastExact kept
  else if pat then
    prefixSweep rest (c :: still) lastExact (p :: kept)
  else
    prefixSweep rest still (Some c) (p :: kept)

dropWhileNotPrefix : String -> List String -> List String
dropWhileNotPrefix _ [] = []
dropWhileNotPrefix c (o :: os) =
  if startsWith o c then o :: os else dropWhileNotPrefix c os

isNonEmpty : List a -> Bool
isNonEmpty [] = False
isNonEmpty _ = True

-- A Product's singletons: one tuple per choice of a member on each Set axis.
singletonsOf : Param -> List Param
singletonsOf (PProduct ax) = map productNorm (axisChoices "" ax)
singletonsOf p = [p]

-- The choices of a member on every Set axis except [keep], whose set stays
-- whole.
axisChoices : String -> List (String, Param) -> List (List (String, Param))
axisChoices _ [] = [[]]
axisChoices keep ((n, PSet (Some xs)) :: rest) =
  let tails = axisChoices keep rest
  if n == keep then
    map ((n, PSet (Some xs)) :: _) tails
  else
    flatMap (x => map ((n, PSet (Some [x])) :: _) tails) xs
axisChoices keep ((n, p) :: rest) = map ((n, p) :: _) (axisChoices keep rest)

-- Products regrouped along the last Set axis by name (see `dantichain`).
canonProducts : List Param -> List Param
canonProducts ps = match lastSetAxis ps
  None => maximalOf ps
  Some axis =>
    let parts = flatMap (splitAround axis) ps
    let groups = fold (acc p => addGroup axis p acc) [] parts
    flatMap (rebuildGroup axis groups) groups

-- A tuple's other axes, split into single members, each with the whole
-- set on [axis].
splitAround : String -> Param -> List Param
splitAround axis (PProduct ax) = map productNorm (axisChoices axis ax)
splitAround _ p = [p]

-- A group: its other axes (as a key that cannot collide, and as axes), and
-- its members on the regroup axis, `None` for the whole axis.
data PGroup = PGroup String (List (String, Param)) (Option (List String))

addGroup : String -> Param -> List PGroup -> List PGroup
addGroup axis p gs =
  let others = otherAxes axis p
  let key = axesKey others
  let members = axisMembers axis p
  match gs
    [] => [PGroup key others members]
    (PGroup k o ms) :: rest =>
      if k == key then
        PGroup k o (unionMembers ms members) :: rest
      else
        PGroup k o ms :: addGroup axis p rest

otherAxes : String -> Param -> List (String, Param)
otherAxes axis (PProduct ax) = filterList (a => fst a /= axis) ax
otherAxes _ _ = []

axisMembers : String -> Param -> Option (List String)
axisMembers axis (PProduct ax) = match lookupAxis axis ax
  Some (PSet (Some xs)) => Some xs
  _ => None
axisMembers _ _ = None

unionMembers : Option (List String) ->
  Option (List String) ->
  Option (List String)
unionMembers (Some a) (Some b) = Some (sortUniqS (a ++ b))
unionMembers _ _ = None

-- An injective key for a group's other axes: every string is written with
-- its length, so no literal can spell another tuple's key.
axesKey : List (String, Param) -> String
axesKey ax = joinWith ";" (map (a => "\{fst a}=\{paramKey (snd a)}") ax)

paramKey : Param -> String
paramKey (PPrefix (Some s)) = "p" ++ lenKey s
paramKey (PPrefix None) = "P"
paramKey (PSet (Some xs)) = "s" ++ joinWith "" (map lenKey xs)
paramKey (PSet None) = "S"
paramKey (PProduct ax) = "x(" ++ axesKey ax ++ ")"
paramKey PUnit = "u"

-- A group less the members a covering group holds: another group whose
-- other axes cover this one's covers each member they share, and the whole
-- group if its members are the whole axis.
rebuildGroup : String -> List PGroup -> PGroup -> List Param
rebuildGroup axis gs (PGroup key others members) =
  let coverers =
    filterList
      (g => match g
        PGroup k o _ => k /= key && dsubN (productNorm others) (productNorm o))
      gs
  if anyList (g => groupMembersOf g == None) coverers then
    []
  else match members
    None => [productNorm others]
    Some xs =>
      let taken = flatMap (g => optionOr [] (groupMembersOf g)) coverers
      match filterList (x => not (contains x taken)) xs
        [] => []
        left => [productNorm ((axis, PSet (Some left)) :: others)]

groupMembersOf : PGroup -> Option (List String)
groupMembersOf (PGroup _ _ ms) = ms

lastSetAxis : List Param -> Option String
lastSetAxis ps = match sortUniqS (flatMap setAxisNames ps)
  [] => None
  names => Some (lastOf names)

setAxisNames : Param -> List String
setAxisNames (PProduct ax) =
  map
    fst
    (filterList
      (a => match snd a
        PSet (Some _) => True
        _ => False)
      ax)
setAxisNames _ = []

lastOf : List String -> String
lastOf [x] = x
lastOf (_ :: rest) = lastOf rest
lastOf [] = ""

-- Sorted by rendering, each rendered once.
sortParams : List Param -> List Param
sortParams ps =
  map
    snd
    (sortByKey
      (a b => stringCompare (fst a) (fst b) /= Gt)
      (map (p => (drenderN p, p)) ps))

-- A stable merge sort by [le], a total "not after" relation.
sortByKey : (a -> a -> Bool) -> List a -> List a
sortByKey _ [] = []
sortByKey _ [x] = [x]
sortByKey le xs =
  let (l, r) = splitHalf xs [] []
  mergeBy le (sortByKey le l) (sortByKey le r)

splitHalf : List a -> List a -> List a -> (List a, List a)
splitHalf [] l r = (l, r)
splitHalf [x] l r = (x :: l, r)
splitHalf (x :: y :: rest) l r = splitHalf rest (x :: l) (y :: r)

mergeBy : (a -> a -> Bool) -> List a -> List a -> List a
mergeBy _ [] ys = ys
mergeBy _ xs [] = xs
mergeBy le (x :: xs) (y :: ys) =
  if le x y then x :: mergeBy le xs (y :: ys) else y :: mergeBy le (x :: xs) ys

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
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false) (mem "anyList" false) (mem "reverseL" false) (mem "lenKey" false))))
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
(DFunDef false "djoinN" ((PCon "PUnit") (PCon "PUnit")) (EVar "PUnit"))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "None")) PWild) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PPrefix" (PCon "None"))) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "a"))) (EBlock (DoLet false false (PVar "ca") (EApp (EVar "prefixConcrete") (EVar "a"))) (DoLet false false (PVar "cb") (EApp (EVar "prefixConcrete") (EVar "b"))) (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "ca")) (EVar "cb")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "k")) (EVar "ca")) (ELit (LString "*"))))))))))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "None")) PWild) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PSet" (PCon "None"))) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EBlock (DoLet false false (PVar "u") (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "a") (EVar "b")))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "u")) (EVar "setCardCap")) (EApp (EVar "PSet") (EVar "None")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "u")))))))
(DFunDef false "djoinN" ((PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EApp (EVar "productNorm") (EApp (EApp (EVar "map") (EApp (EApp (EVar "joinAxis") (EVar "ax")) (EVar "bx"))) (EApp (EApp (EVar "axisUnion") (EVar "ax")) (EVar "bx")))))
(DFunDef false "djoinN" ((PVar "p") PWild) (EVar "p"))
(DTypeSig true "dantichain" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "dantichain" ((PVar "ps")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "map") (EVar "canonParam")) (EVar "ps"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "isSubTop")) (EVar "cs")) (EListLit (EApp (EVar "subTopOf") (EApp (EVar "headParam") (EVar "cs")))) (EMatch (EVar "cs") (arm (PCons (PCon "PSet" PWild) PWild) () (EListLit (EApp (EVar "PSet") (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EApp (EApp (EVar "flatMap") (EVar "setMembers")) (EVar "cs"))))))) (arm (PCons (PCon "PPrefix" PWild) PWild) () (EApp (EVar "sortParams") (EApp (EVar "maximalPrefixes") (EVar "cs")))) (arm (PCons (PCon "PProduct" PWild) PWild) () (EApp (EVar "sortParams") (EApp (EVar "canonProducts") (EVar "cs")))) (arm (PList) () (EListLit)) (arm PWild () (EApp (EVar "sortParams") (EApp (EVar "maximalOf") (EVar "cs")))))))))
(DTypeSig true "writtenSetProblem" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "writtenSetProblem" ((PVar "ps")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "map") (EVar "canonParam")) (EVar "ps"))) (DoLet false false (PVar "written") (EMatch (EVar "cs") (arm (PCons (PCon "PSet" PWild) PWild) () (EApp (EVar "dantichain") (EVar "cs"))) (arm PWild () (EApp (EVar "maximalOf") (EVar "cs"))))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "written"))) (DoLet false false (PVar "bigs") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (EVar "setCardCap")))) (EApp (EApp (EVar "map") (EVar "largestSet")) (EBinOp "++" (EVar "written") (EApp (EVar "dantichain") (EVar "cs")))))) (DoExpr (EIf (EBinOp ">" (EVar "n") (EVar "setCardCap")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a bound admits at most ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "setCardCap")))) (ELit (LString " elements of one label, and this one writes "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "; write a pattern that covers several of them")))) (EMatch (EVar "bigs") (arm (PCons (PVar "big") PWild) () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a set holds at most ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "setCardCap")))) (ELit (LString " members, and this one has "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "big")))) (ELit (LString ""))))) (arm (PList) () (EVar "None")))))))
(DTypeSig true "dsubAny" (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Bool"))))
(DFunDef false "dsubAny" ((PVar "p") (PVar "qs")) (EBlock (DoLet false false (PVar "cp") (EApp (EVar "canonParam") (EVar "p"))) (DoLet false false (PVar "cqs") (EApp (EApp (EVar "map") (EVar "canonParam")) (EVar "qs"))) (DoExpr (EBinOp "||" (EApp (EApp (EVar "anyList") (EApp (EVar "dsubN") (EVar "cp"))) (EVar "cqs")) (EMatch (EVar "cp") (arm (PCon "PProduct" PWild) () (EApp (EApp (EVar "allList") (ELam ((PVar "s")) (EApp (EApp (EVar "anyList") (EApp (EVar "dsubN") (EVar "s"))) (EVar "cqs")))) (EApp (EVar "singletonsOf") (EVar "cp")))) (arm PWild () (EVar "False")))))))
(DTypeSig false "setMembers" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "setMembers" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EVar "xs"))
(DFunDef false "setMembers" (PWild) (EListLit))
(DTypeSig false "largestSet" (TyFun (TyCon "Param") (TyCon "Int")))
(DFunDef false "largestSet" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EApp (EVar "listLen") (EVar "xs")))
(DFunDef false "largestSet" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "a")) (EApp (EApp (EVar "max") (EVar "acc")) (EApp (EVar "largestSet") (EApp (EVar "snd") (EVar "a")))))) (ELit (LInt 0))) (EVar "ax")))
(DFunDef false "largestSet" (PWild) (ELit (LInt 0)))
(DTypeSig false "headParam" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Param")))
(DFunDef false "headParam" ((PCons (PVar "p") PWild)) (EVar "p"))
(DFunDef false "headParam" ((PList)) (EVar "PUnit"))
(DTypeSig false "maximalOf" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "maximalOf" ((PVar "ps")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EVar "keepMaximal") (EVar "p")) (EVar "acc")))) (EListLit)) (EVar "ps")))
(DTypeSig false "keepMaximal" (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "keepMaximal" ((PVar "p") (PVar "acc")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "q")) (EApp (EApp (EVar "dsubN") (EVar "p")) (EVar "q")))) (EVar "acc")) (EVar "acc") (EBinOp "::" (EVar "p") (EApp (EApp (EVar "filterList") (ELam ((PVar "q")) (EApp (EVar "not") (EApp (EApp (EVar "dsubN") (EVar "q")) (EVar "p"))))) (EVar "acc")))))
(DTypeSig false "maximalPrefixes" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "maximalPrefixes" ((PVar "ps")) (EApp (EApp (EApp (EApp (EVar "prefixSweep") (EApp (EApp (EVar "sortByKey") (EVar "prefixOrder")) (EApp (EApp (EVar "map") (EVar "prefixEntry")) (EVar "ps")))) (EListLit)) (EVar "None")) (EListLit)))
(DData Private "PrefixEntry" () ((variant "PrefixEntry" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "Param")))) ())
(DTypeSig false "prefixEntry" (TyFun (TyCon "Param") (TyCon "PrefixEntry")))
(DFunDef false "prefixEntry" ((PAs "p" (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EApp (EApp (EVar "PrefixEntry") (EApp (EVar "prefixConcrete") (EVar "s"))) (EVar "True")) (EVar "p")) (EApp (EApp (EApp (EVar "PrefixEntry") (EVar "s")) (EVar "False")) (EVar "p"))))
(DFunDef false "prefixEntry" ((PVar "p")) (EApp (EApp (EApp (EVar "PrefixEntry") (ELit (LString ""))) (EVar "True")) (EVar "p")))
(DTypeSig false "prefixOrder" (TyFun (TyCon "PrefixEntry") (TyFun (TyCon "PrefixEntry") (TyCon "Bool"))))
(DFunDef false "prefixOrder" ((PCon "PrefixEntry" (PVar "a") (PVar "pa") PWild) (PCon "PrefixEntry" (PVar "b") (PVar "pb") PWild)) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "a")) (EVar "b")) (arm (PCon "Lt") () (EVar "True")) (arm (PCon "Gt") () (EVar "False")) (arm (PCon "Eq") () (EBinOp "||" (EVar "pa") (EApp (EVar "not") (EVar "pb"))))))
(DTypeSig false "prefixSweep" (TyFun (TyApp (TyCon "List") (TyCon "PrefixEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))))
(DFunDef false "prefixSweep" ((PList) PWild PWild (PVar "kept")) (EVar "kept"))
(DFunDef false "prefixSweep" ((PCons (PCon "PrefixEntry" (PVar "c") (PVar "pat") (PVar "p")) (PVar "rest")) (PVar "open") (PVar "lastExact") (PVar "kept")) (EBlock (DoLet false false (PVar "still") (EApp (EApp (EVar "dropWhileNotPrefix") (EVar "c")) (EVar "open"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isNonEmpty") (EVar "still")) (EBinOp "&&" (EApp (EVar "not") (EVar "pat")) (EBinOp "==" (EVar "lastExact") (EApp (EVar "Some") (EVar "c"))))) (EApp (EApp (EApp (EApp (EVar "prefixSweep") (EVar "rest")) (EVar "still")) (EVar "lastExact")) (EVar "kept")) (EIf (EVar "pat") (EApp (EApp (EApp (EApp (EVar "prefixSweep") (EVar "rest")) (EBinOp "::" (EVar "c") (EVar "still"))) (EVar "lastExact")) (EBinOp "::" (EVar "p") (EVar "kept"))) (EApp (EApp (EApp (EApp (EVar "prefixSweep") (EVar "rest")) (EVar "still")) (EApp (EVar "Some") (EVar "c"))) (EBinOp "::" (EVar "p") (EVar "kept"))))))))
(DTypeSig false "dropWhileNotPrefix" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dropWhileNotPrefix" (PWild (PList)) (EListLit))
(DFunDef false "dropWhileNotPrefix" ((PVar "c") (PCons (PVar "o") (PVar "os"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "o")) (EVar "c")) (EBinOp "::" (EVar "o") (EVar "os")) (EApp (EApp (EVar "dropWhileNotPrefix") (EVar "c")) (EVar "os"))))
(DTypeSig false "isNonEmpty" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isNonEmpty" ((PList)) (EVar "False"))
(DFunDef false "isNonEmpty" (PWild) (EVar "True"))
(DTypeSig false "singletonsOf" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "singletonsOf" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EVar "map") (EVar "productNorm")) (EApp (EApp (EVar "axisChoices") (ELit (LString ""))) (EVar "ax"))))
(DFunDef false "singletonsOf" ((PVar "p")) (EListLit (EVar "p")))
(DTypeSig false "axisChoices" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))))
(DFunDef false "axisChoices" (PWild (PList)) (EListLit (EListLit)))
(DFunDef false "axisChoices" ((PVar "keep") (PCons (PTuple (PVar "n") (PCon "PSet" (PCon "Some" (PVar "xs")))) (PVar "rest"))) (EBlock (DoLet false false (PVar "tails") (EApp (EApp (EVar "axisChoices") (EVar "keep")) (EVar "rest"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (EVar "keep")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "xs")))) (EVar "_s")))) (EVar "tails")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "x")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "x"))))) (EVar "_s")))) (EVar "tails")))) (EVar "xs"))))))
(DFunDef false "axisChoices" ((PVar "keep") (PCons (PTuple (PVar "n") (PVar "p")) (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "n") (EVar "p")) (EVar "_s")))) (EApp (EApp (EVar "axisChoices") (EVar "keep")) (EVar "rest"))))
(DTypeSig false "canonProducts" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "canonProducts" ((PVar "ps")) (EMatch (EApp (EVar "lastSetAxis") (EVar "ps")) (arm (PCon "None") () (EApp (EVar "maximalOf") (EVar "ps"))) (arm (PCon "Some" (PVar "axis")) () (EBlock (DoLet false false (PVar "parts") (EApp (EApp (EVar "flatMap") (EApp (EVar "splitAround") (EVar "axis"))) (EVar "ps"))) (DoLet false false (PVar "groups") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EApp (EVar "addGroup") (EVar "axis")) (EVar "p")) (EVar "acc")))) (EListLit)) (EVar "parts"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "rebuildGroup") (EVar "axis")) (EVar "groups"))) (EVar "groups")))))))
(DTypeSig false "splitAround" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "splitAround" ((PVar "axis") (PCon "PProduct" (PVar "ax"))) (EApp (EApp (EVar "map") (EVar "productNorm")) (EApp (EApp (EVar "axisChoices") (EVar "axis")) (EVar "ax"))))
(DFunDef false "splitAround" (PWild (PVar "p")) (EListLit (EVar "p")))
(DData Private "PGroup" () ((variant "PGroup" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "addGroup" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "PGroup")) (TyApp (TyCon "List") (TyCon "PGroup"))))))
(DFunDef false "addGroup" ((PVar "axis") (PVar "p") (PVar "gs")) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "otherAxes") (EVar "axis")) (EVar "p"))) (DoLet false false (PVar "key") (EApp (EVar "axesKey") (EVar "others"))) (DoLet false false (PVar "members") (EApp (EApp (EVar "axisMembers") (EVar "axis")) (EVar "p"))) (DoExpr (EMatch (EVar "gs") (arm (PList) () (EListLit (EApp (EApp (EApp (EVar "PGroup") (EVar "key")) (EVar "others")) (EVar "members")))) (arm (PCons (PCon "PGroup" (PVar "k") (PVar "o") (PVar "ms")) (PVar "rest")) () (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EBinOp "::" (EApp (EApp (EApp (EVar "PGroup") (EVar "k")) (EVar "o")) (EApp (EApp (EVar "unionMembers") (EVar "ms")) (EVar "members"))) (EVar "rest")) (EBinOp "::" (EApp (EApp (EApp (EVar "PGroup") (EVar "k")) (EVar "o")) (EVar "ms")) (EApp (EApp (EApp (EVar "addGroup") (EVar "axis")) (EVar "p")) (EVar "rest")))))))))
(DTypeSig false "otherAxes" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "otherAxes" ((PVar "axis") (PCon "PProduct" (PVar "ax"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EBinOp "/=" (EApp (EVar "fst") (EVar "a")) (EVar "axis")))) (EVar "ax")))
(DFunDef false "otherAxes" (PWild PWild) (EListLit))
(DTypeSig false "axisMembers" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "axisMembers" ((PVar "axis") (PCon "PProduct" (PVar "ax"))) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "axis")) (EVar "ax")) (arm (PCon "Some" (PCon "PSet" (PCon "Some" (PVar "xs")))) () (EApp (EVar "Some") (EVar "xs"))) (arm PWild () (EVar "None"))))
(DFunDef false "axisMembers" (PWild PWild) (EVar "None"))
(DTypeSig false "unionMembers" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "unionMembers" ((PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "a") (EVar "b")))))
(DFunDef false "unionMembers" (PWild PWild) (EVar "None"))
(DTypeSig false "axesKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "axesKey" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "fst") (EVar "a")))) (ELit (LString "="))) (EApp (EVar "display") (EApp (EVar "paramKey") (EApp (EVar "snd") (EVar "a"))))) (ELit (LString ""))))) (EVar "ax"))))
(DTypeSig false "paramKey" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "paramKey" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EBinOp "++" (ELit (LString "p")) (EApp (EVar "lenKey") (EVar "s"))))
(DFunDef false "paramKey" ((PCon "PPrefix" (PCon "None"))) (ELit (LString "P")))
(DFunDef false "paramKey" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EBinOp "++" (ELit (LString "s")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "lenKey")) (EVar "xs")))))
(DFunDef false "paramKey" ((PCon "PSet" (PCon "None"))) (ELit (LString "S")))
(DFunDef false "paramKey" ((PCon "PProduct" (PVar "ax"))) (EBinOp "++" (EBinOp "++" (ELit (LString "x(")) (EApp (EVar "axesKey") (EVar "ax"))) (ELit (LString ")"))))
(DFunDef false "paramKey" ((PCon "PUnit")) (ELit (LString "u")))
(DTypeSig false "rebuildGroup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PGroup")) (TyFun (TyCon "PGroup") (TyApp (TyCon "List") (TyCon "Param"))))))
(DFunDef false "rebuildGroup" ((PVar "axis") (PVar "gs") (PCon "PGroup" (PVar "key") (PVar "others") (PVar "members"))) (EBlock (DoLet false false (PVar "coverers") (EApp (EApp (EVar "filterList") (ELam ((PVar "g")) (EMatch (EVar "g") (arm (PCon "PGroup" (PVar "k") (PVar "o") PWild) () (EBinOp "&&" (EBinOp "/=" (EVar "k") (EVar "key")) (EApp (EApp (EVar "dsubN") (EApp (EVar "productNorm") (EVar "others"))) (EApp (EVar "productNorm") (EVar "o")))))))) (EVar "gs"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "g")) (EBinOp "==" (EApp (EVar "groupMembersOf") (EVar "g")) (EVar "None")))) (EVar "coverers")) (EListLit) (EMatch (EVar "members") (arm (PCon "None") () (EListLit (EApp (EVar "productNorm") (EVar "others")))) (arm (PCon "Some" (PVar "xs")) () (EBlock (DoLet false false (PVar "taken") (EApp (EApp (EVar "flatMap") (ELam ((PVar "g")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EVar "groupMembersOf") (EVar "g"))))) (EVar "coverers"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "x")) (EVar "taken"))))) (EVar "xs")) (arm (PList) () (EListLit)) (arm (PVar "left") () (EListLit (EApp (EVar "productNorm") (EBinOp "::" (ETuple (EVar "axis") (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "left")))) (EVar "others"))))))))))))))
(DTypeSig false "groupMembersOf" (TyFun (TyCon "PGroup") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "groupMembersOf" ((PCon "PGroup" PWild PWild (PVar "ms"))) (EVar "ms"))
(DTypeSig false "lastSetAxis" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lastSetAxis" ((PVar "ps")) (EMatch (EApp (EVar "sortUniqS") (EApp (EApp (EVar "flatMap") (EVar "setAxisNames")) (EVar "ps"))) (arm (PList) () (EVar "None")) (arm (PVar "names") () (EApp (EVar "Some") (EApp (EVar "lastOf") (EVar "names"))))))
(DTypeSig false "setAxisNames" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "setAxisNames" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EMatch (EApp (EVar "snd") (EVar "a")) (arm (PCon "PSet" (PCon "Some" PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))) (EVar "ax"))))
(DFunDef false "setAxisNames" (PWild) (EListLit))
(DTypeSig false "lastOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOf" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOf") (EVar "rest")))
(DFunDef false "lastOf" ((PList)) (ELit (LString "")))
(DTypeSig false "sortParams" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "sortParams" ((PVar "ps")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "sortByKey") (ELam ((PVar "a") (PVar "b")) (EBinOp "/=" (EApp (EApp (EVar "stringCompare") (EApp (EVar "fst") (EVar "a"))) (EApp (EVar "fst") (EVar "b"))) (EVar "Gt")))) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "drenderN") (EVar "p")) (EVar "p")))) (EVar "ps")))))
(DTypeSig false "sortByKey" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "sortByKey" (PWild (PList)) (EListLit))
(DFunDef false "sortByKey" (PWild (PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "sortByKey" ((PVar "le") (PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "splitHalf") (EVar "xs")) (EListLit)) (EListLit))) (DoExpr (EApp (EApp (EApp (EVar "mergeBy") (EVar "le")) (EApp (EApp (EVar "sortByKey") (EVar "le")) (EVar "l"))) (EApp (EApp (EVar "sortByKey") (EVar "le")) (EVar "r"))))))
(DTypeSig false "splitHalf" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "splitHalf" ((PList) (PVar "l") (PVar "r")) (ETuple (EVar "l") (EVar "r")))
(DFunDef false "splitHalf" ((PList (PVar "x")) (PVar "l") (PVar "r")) (ETuple (EBinOp "::" (EVar "x") (EVar "l")) (EVar "r")))
(DFunDef false "splitHalf" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest"))) (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "splitHalf") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "l"))) (EBinOp "::" (EVar "y") (EVar "r"))))
(DTypeSig false "mergeBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "mergeBy" (PWild (PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "mergeBy" (PWild (PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "mergeBy" ((PVar "le") (PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "le") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "mergeBy") (EVar "le")) (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "mergeBy") (EVar "le")) (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys")))))
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
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false) (mem "anyList" false) (mem "reverseL" false) (mem "lenKey" false))))
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
(DFunDef false "djoinN" ((PCon "PUnit") (PCon "PUnit")) (EVar "PUnit"))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "None")) PWild) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PPrefix" (PCon "None"))) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "a"))) (EBlock (DoLet false false (PVar "ca") (EApp (EVar "prefixConcrete") (EVar "a"))) (DoLet false false (PVar "cb") (EApp (EVar "prefixConcrete") (EVar "b"))) (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "ca")) (EVar "cb")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "k")) (EVar "ca")) (ELit (LString "*"))))))))))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "None")) PWild) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PSet" (PCon "None"))) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EBlock (DoLet false false (PVar "u") (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "a") (EVar "b")))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "u")) (EVar "setCardCap")) (EApp (EVar "PSet") (EVar "None")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "u")))))))
(DFunDef false "djoinN" ((PCon "PProduct" (PVar "ax")) (PCon "PProduct" (PVar "bx"))) (EApp (EVar "productNorm") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "joinAxis") (EVar "ax")) (EVar "bx"))) (EApp (EApp (EVar "axisUnion") (EVar "ax")) (EVar "bx")))))
(DFunDef false "djoinN" ((PVar "p") PWild) (EVar "p"))
(DTypeSig true "dantichain" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "dantichain" ((PVar "ps")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EMethodRef "map") (EVar "canonParam")) (EVar "ps"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "isSubTop")) (EVar "cs")) (EListLit (EApp (EVar "subTopOf") (EApp (EVar "headParam") (EVar "cs")))) (EMatch (EVar "cs") (arm (PCons (PCon "PSet" PWild) PWild) () (EListLit (EApp (EVar "PSet") (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EApp (EApp (EDictApp "flatMap") (EVar "setMembers")) (EVar "cs"))))))) (arm (PCons (PCon "PPrefix" PWild) PWild) () (EApp (EVar "sortParams") (EApp (EVar "maximalPrefixes") (EVar "cs")))) (arm (PCons (PCon "PProduct" PWild) PWild) () (EApp (EVar "sortParams") (EApp (EVar "canonProducts") (EVar "cs")))) (arm (PList) () (EListLit)) (arm PWild () (EApp (EVar "sortParams") (EApp (EVar "maximalOf") (EVar "cs")))))))))
(DTypeSig true "writtenSetProblem" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "writtenSetProblem" ((PVar "ps")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EMethodRef "map") (EVar "canonParam")) (EVar "ps"))) (DoLet false false (PVar "written") (EMatch (EVar "cs") (arm (PCons (PCon "PSet" PWild) PWild) () (EApp (EVar "dantichain") (EVar "cs"))) (arm PWild () (EApp (EVar "maximalOf") (EVar "cs"))))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "written"))) (DoLet false false (PVar "bigs") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (EVar "setCardCap")))) (EApp (EApp (EMethodRef "map") (EVar "largestSet")) (EBinOp "++" (EVar "written") (EApp (EVar "dantichain") (EVar "cs")))))) (DoExpr (EIf (EBinOp ">" (EVar "n") (EVar "setCardCap")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a bound admits at most ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "setCardCap")))) (ELit (LString " elements of one label, and this one writes "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "; write a pattern that covers several of them")))) (EMatch (EVar "bigs") (arm (PCons (PVar "big") PWild) () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a set holds at most ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "setCardCap")))) (ELit (LString " members, and this one has "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "big")))) (ELit (LString ""))))) (arm (PList) () (EVar "None")))))))
(DTypeSig true "dsubAny" (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Bool"))))
(DFunDef false "dsubAny" ((PVar "p") (PVar "qs")) (EBlock (DoLet false false (PVar "cp") (EApp (EVar "canonParam") (EVar "p"))) (DoLet false false (PVar "cqs") (EApp (EApp (EMethodRef "map") (EVar "canonParam")) (EVar "qs"))) (DoExpr (EBinOp "||" (EApp (EApp (EVar "anyList") (EApp (EVar "dsubN") (EVar "cp"))) (EVar "cqs")) (EMatch (EVar "cp") (arm (PCon "PProduct" PWild) () (EApp (EApp (EVar "allList") (ELam ((PVar "s")) (EApp (EApp (EVar "anyList") (EApp (EVar "dsubN") (EVar "s"))) (EVar "cqs")))) (EApp (EVar "singletonsOf") (EVar "cp")))) (arm PWild () (EVar "False")))))))
(DTypeSig false "setMembers" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "setMembers" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EVar "xs"))
(DFunDef false "setMembers" (PWild) (EListLit))
(DTypeSig false "largestSet" (TyFun (TyCon "Param") (TyCon "Int")))
(DFunDef false "largestSet" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EApp (EVar "listLen") (EVar "xs")))
(DFunDef false "largestSet" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "a")) (EApp (EApp (EMethodRef "max") (EVar "acc")) (EApp (EVar "largestSet") (EApp (EVar "snd") (EVar "a")))))) (ELit (LInt 0))) (EVar "ax")))
(DFunDef false "largestSet" (PWild) (ELit (LInt 0)))
(DTypeSig false "headParam" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Param")))
(DFunDef false "headParam" ((PCons (PVar "p") PWild)) (EVar "p"))
(DFunDef false "headParam" ((PList)) (EVar "PUnit"))
(DTypeSig false "maximalOf" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "maximalOf" ((PVar "ps")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EVar "keepMaximal") (EVar "p")) (EVar "acc")))) (EListLit)) (EVar "ps")))
(DTypeSig false "keepMaximal" (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "keepMaximal" ((PVar "p") (PVar "acc")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "q")) (EApp (EApp (EVar "dsubN") (EVar "p")) (EVar "q")))) (EVar "acc")) (EVar "acc") (EBinOp "::" (EVar "p") (EApp (EApp (EVar "filterList") (ELam ((PVar "q")) (EApp (EVar "not") (EApp (EApp (EVar "dsubN") (EVar "q")) (EVar "p"))))) (EVar "acc")))))
(DTypeSig false "maximalPrefixes" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "maximalPrefixes" ((PVar "ps")) (EApp (EApp (EApp (EApp (EVar "prefixSweep") (EApp (EApp (EVar "sortByKey") (EVar "prefixOrder")) (EApp (EApp (EMethodRef "map") (EVar "prefixEntry")) (EVar "ps")))) (EListLit)) (EVar "None")) (EListLit)))
(DData Private "PrefixEntry" () ((variant "PrefixEntry" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "Param")))) ())
(DTypeSig false "prefixEntry" (TyFun (TyCon "Param") (TyCon "PrefixEntry")))
(DFunDef false "prefixEntry" ((PAs "p" (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EApp (EApp (EVar "PrefixEntry") (EApp (EVar "prefixConcrete") (EVar "s"))) (EVar "True")) (EVar "p")) (EApp (EApp (EApp (EVar "PrefixEntry") (EVar "s")) (EVar "False")) (EVar "p"))))
(DFunDef false "prefixEntry" ((PVar "p")) (EApp (EApp (EApp (EVar "PrefixEntry") (ELit (LString ""))) (EVar "True")) (EVar "p")))
(DTypeSig false "prefixOrder" (TyFun (TyCon "PrefixEntry") (TyFun (TyCon "PrefixEntry") (TyCon "Bool"))))
(DFunDef false "prefixOrder" ((PCon "PrefixEntry" (PVar "a") (PVar "pa") PWild) (PCon "PrefixEntry" (PVar "b") (PVar "pb") PWild)) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "a")) (EVar "b")) (arm (PCon "Lt") () (EVar "True")) (arm (PCon "Gt") () (EVar "False")) (arm (PCon "Eq") () (EBinOp "||" (EVar "pa") (EApp (EVar "not") (EVar "pb"))))))
(DTypeSig false "prefixSweep" (TyFun (TyApp (TyCon "List") (TyCon "PrefixEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))))
(DFunDef false "prefixSweep" ((PList) PWild PWild (PVar "kept")) (EVar "kept"))
(DFunDef false "prefixSweep" ((PCons (PCon "PrefixEntry" (PVar "c") (PVar "pat") (PVar "p")) (PVar "rest")) (PVar "open") (PVar "lastExact") (PVar "kept")) (EBlock (DoLet false false (PVar "still") (EApp (EApp (EVar "dropWhileNotPrefix") (EVar "c")) (EVar "open"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isNonEmpty") (EVar "still")) (EBinOp "&&" (EApp (EVar "not") (EVar "pat")) (EBinOp "==" (EVar "lastExact") (EApp (EVar "Some") (EVar "c"))))) (EApp (EApp (EApp (EApp (EVar "prefixSweep") (EVar "rest")) (EVar "still")) (EVar "lastExact")) (EVar "kept")) (EIf (EVar "pat") (EApp (EApp (EApp (EApp (EVar "prefixSweep") (EVar "rest")) (EBinOp "::" (EVar "c") (EVar "still"))) (EVar "lastExact")) (EBinOp "::" (EVar "p") (EVar "kept"))) (EApp (EApp (EApp (EApp (EVar "prefixSweep") (EVar "rest")) (EVar "still")) (EApp (EVar "Some") (EVar "c"))) (EBinOp "::" (EVar "p") (EVar "kept"))))))))
(DTypeSig false "dropWhileNotPrefix" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dropWhileNotPrefix" (PWild (PList)) (EListLit))
(DFunDef false "dropWhileNotPrefix" ((PVar "c") (PCons (PVar "o") (PVar "os"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "o")) (EVar "c")) (EBinOp "::" (EVar "o") (EVar "os")) (EApp (EApp (EVar "dropWhileNotPrefix") (EVar "c")) (EVar "os"))))
(DTypeSig false "isNonEmpty" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isNonEmpty" ((PList)) (EVar "False"))
(DFunDef false "isNonEmpty" (PWild) (EVar "True"))
(DTypeSig false "singletonsOf" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "singletonsOf" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EMethodRef "map") (EVar "productNorm")) (EApp (EApp (EVar "axisChoices") (ELit (LString ""))) (EVar "ax"))))
(DFunDef false "singletonsOf" ((PVar "p")) (EListLit (EVar "p")))
(DTypeSig false "axisChoices" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))))
(DFunDef false "axisChoices" (PWild (PList)) (EListLit (EListLit)))
(DFunDef false "axisChoices" ((PVar "keep") (PCons (PTuple (PVar "n") (PCon "PSet" (PCon "Some" (PVar "xs")))) (PVar "rest"))) (EBlock (DoLet false false (PVar "tails") (EApp (EApp (EVar "axisChoices") (EVar "keep")) (EVar "rest"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (EVar "keep")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "xs")))) (EVar "_s")))) (EVar "tails")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "x")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "x"))))) (EVar "_s")))) (EVar "tails")))) (EVar "xs"))))))
(DFunDef false "axisChoices" ((PVar "keep") (PCons (PTuple (PVar "n") (PVar "p")) (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "n") (EVar "p")) (EVar "_s")))) (EApp (EApp (EVar "axisChoices") (EVar "keep")) (EVar "rest"))))
(DTypeSig false "canonProducts" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "canonProducts" ((PVar "ps")) (EMatch (EApp (EVar "lastSetAxis") (EVar "ps")) (arm (PCon "None") () (EApp (EVar "maximalOf") (EVar "ps"))) (arm (PCon "Some" (PVar "axis")) () (EBlock (DoLet false false (PVar "parts") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "splitAround") (EVar "axis"))) (EVar "ps"))) (DoLet false false (PVar "groups") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EApp (EVar "addGroup") (EVar "axis")) (EVar "p")) (EVar "acc")))) (EListLit)) (EVar "parts"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "rebuildGroup") (EVar "axis")) (EVar "groups"))) (EVar "groups")))))))
(DTypeSig false "splitAround" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "splitAround" ((PVar "axis") (PCon "PProduct" (PVar "ax"))) (EApp (EApp (EMethodRef "map") (EVar "productNorm")) (EApp (EApp (EVar "axisChoices") (EVar "axis")) (EVar "ax"))))
(DFunDef false "splitAround" (PWild (PVar "p")) (EListLit (EVar "p")))
(DData Private "PGroup" () ((variant "PGroup" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "addGroup" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "PGroup")) (TyApp (TyCon "List") (TyCon "PGroup"))))))
(DFunDef false "addGroup" ((PVar "axis") (PVar "p") (PVar "gs")) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "otherAxes") (EVar "axis")) (EVar "p"))) (DoLet false false (PVar "key") (EApp (EVar "axesKey") (EVar "others"))) (DoLet false false (PVar "members") (EApp (EApp (EVar "axisMembers") (EVar "axis")) (EVar "p"))) (DoExpr (EMatch (EVar "gs") (arm (PList) () (EListLit (EApp (EApp (EApp (EVar "PGroup") (EVar "key")) (EVar "others")) (EVar "members")))) (arm (PCons (PCon "PGroup" (PVar "k") (PVar "o") (PVar "ms")) (PVar "rest")) () (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EBinOp "::" (EApp (EApp (EApp (EVar "PGroup") (EVar "k")) (EVar "o")) (EApp (EApp (EVar "unionMembers") (EVar "ms")) (EVar "members"))) (EVar "rest")) (EBinOp "::" (EApp (EApp (EApp (EVar "PGroup") (EVar "k")) (EVar "o")) (EVar "ms")) (EApp (EApp (EApp (EVar "addGroup") (EVar "axis")) (EVar "p")) (EVar "rest")))))))))
(DTypeSig false "otherAxes" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "otherAxes" ((PVar "axis") (PCon "PProduct" (PVar "ax"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EBinOp "/=" (EApp (EVar "fst") (EVar "a")) (EVar "axis")))) (EVar "ax")))
(DFunDef false "otherAxes" (PWild PWild) (EListLit))
(DTypeSig false "axisMembers" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "axisMembers" ((PVar "axis") (PCon "PProduct" (PVar "ax"))) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "axis")) (EVar "ax")) (arm (PCon "Some" (PCon "PSet" (PCon "Some" (PVar "xs")))) () (EApp (EVar "Some") (EVar "xs"))) (arm PWild () (EVar "None"))))
(DFunDef false "axisMembers" (PWild PWild) (EVar "None"))
(DTypeSig false "unionMembers" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "unionMembers" ((PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "a") (EVar "b")))))
(DFunDef false "unionMembers" (PWild PWild) (EVar "None"))
(DTypeSig false "axesKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "axesKey" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "a")))) (ELit (LString "="))) (EApp (EMethodRef "display") (EApp (EVar "paramKey") (EApp (EVar "snd") (EVar "a"))))) (ELit (LString ""))))) (EVar "ax"))))
(DTypeSig false "paramKey" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "paramKey" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EBinOp "++" (ELit (LString "p")) (EApp (EVar "lenKey") (EVar "s"))))
(DFunDef false "paramKey" ((PCon "PPrefix" (PCon "None"))) (ELit (LString "P")))
(DFunDef false "paramKey" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EBinOp "++" (ELit (LString "s")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "lenKey")) (EVar "xs")))))
(DFunDef false "paramKey" ((PCon "PSet" (PCon "None"))) (ELit (LString "S")))
(DFunDef false "paramKey" ((PCon "PProduct" (PVar "ax"))) (EBinOp "++" (EBinOp "++" (ELit (LString "x(")) (EApp (EVar "axesKey") (EVar "ax"))) (ELit (LString ")"))))
(DFunDef false "paramKey" ((PCon "PUnit")) (ELit (LString "u")))
(DTypeSig false "rebuildGroup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PGroup")) (TyFun (TyCon "PGroup") (TyApp (TyCon "List") (TyCon "Param"))))))
(DFunDef false "rebuildGroup" ((PVar "axis") (PVar "gs") (PCon "PGroup" (PVar "key") (PVar "others") (PVar "members"))) (EBlock (DoLet false false (PVar "coverers") (EApp (EApp (EVar "filterList") (ELam ((PVar "g")) (EMatch (EVar "g") (arm (PCon "PGroup" (PVar "k") (PVar "o") PWild) () (EBinOp "&&" (EBinOp "/=" (EVar "k") (EVar "key")) (EApp (EApp (EVar "dsubN") (EApp (EVar "productNorm") (EVar "others"))) (EApp (EVar "productNorm") (EVar "o")))))))) (EVar "gs"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "g")) (EBinOp "==" (EApp (EVar "groupMembersOf") (EVar "g")) (EVar "None")))) (EVar "coverers")) (EListLit) (EMatch (EVar "members") (arm (PCon "None") () (EListLit (EApp (EVar "productNorm") (EVar "others")))) (arm (PCon "Some" (PVar "xs")) () (EBlock (DoLet false false (PVar "taken") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "g")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EVar "groupMembersOf") (EVar "g"))))) (EVar "coverers"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "x")) (EVar "taken"))))) (EVar "xs")) (arm (PList) () (EListLit)) (arm (PVar "left") () (EListLit (EApp (EVar "productNorm") (EBinOp "::" (ETuple (EVar "axis") (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "left")))) (EVar "others"))))))))))))))
(DTypeSig false "groupMembersOf" (TyFun (TyCon "PGroup") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "groupMembersOf" ((PCon "PGroup" PWild PWild (PVar "ms"))) (EVar "ms"))
(DTypeSig false "lastSetAxis" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lastSetAxis" ((PVar "ps")) (EMatch (EApp (EVar "sortUniqS") (EApp (EApp (EDictApp "flatMap") (EVar "setAxisNames")) (EVar "ps"))) (arm (PList) () (EVar "None")) (arm (PVar "names") () (EApp (EVar "Some") (EApp (EVar "lastOf") (EVar "names"))))))
(DTypeSig false "setAxisNames" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "setAxisNames" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EMatch (EApp (EVar "snd") (EVar "a")) (arm (PCon "PSet" (PCon "Some" PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))) (EVar "ax"))))
(DFunDef false "setAxisNames" (PWild) (EListLit))
(DTypeSig false "lastOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOf" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOf") (EVar "rest")))
(DFunDef false "lastOf" ((PList)) (ELit (LString "")))
(DTypeSig false "sortParams" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "sortParams" ((PVar "ps")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "sortByKey") (ELam ((PVar "a") (PVar "b")) (EBinOp "/=" (EApp (EApp (EVar "stringCompare") (EApp (EVar "fst") (EVar "a"))) (EApp (EVar "fst") (EVar "b"))) (EVar "Gt")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "drenderN") (EVar "p")) (EVar "p")))) (EVar "ps")))))
(DTypeSig false "sortByKey" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "sortByKey" (PWild (PList)) (EListLit))
(DFunDef false "sortByKey" (PWild (PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "sortByKey" ((PVar "le") (PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "splitHalf") (EVar "xs")) (EListLit)) (EListLit))) (DoExpr (EApp (EApp (EApp (EVar "mergeBy") (EVar "le")) (EApp (EApp (EVar "sortByKey") (EVar "le")) (EVar "l"))) (EApp (EApp (EVar "sortByKey") (EVar "le")) (EVar "r"))))))
(DTypeSig false "splitHalf" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "splitHalf" ((PList) (PVar "l") (PVar "r")) (ETuple (EVar "l") (EVar "r")))
(DFunDef false "splitHalf" ((PList (PVar "x")) (PVar "l") (PVar "r")) (ETuple (EBinOp "::" (EVar "x") (EVar "l")) (EVar "r")))
(DFunDef false "splitHalf" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest"))) (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "splitHalf") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "l"))) (EBinOp "::" (EVar "y") (EVar "r"))))
(DTypeSig false "mergeBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "mergeBy" (PWild (PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "mergeBy" (PWild (PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "mergeBy" ((PVar "le") (PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "le") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "mergeBy") (EVar "le")) (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "mergeBy") (EVar "le")) (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys")))))
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
