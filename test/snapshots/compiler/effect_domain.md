# META
source_lines=887
stages=DESUGAR,MARK
# SOURCE
-- Concrete authority domains: the lattice each effect label's parameter is
-- drawn from. Domain operations do not depend on inference state, syntax, or
-- dictionary selection; atoms and rows are built over them in `effect_rows`.

import support.util.{
  listLen, filterList, joinWith, sortUniqS, startsWith, contains, allList,
  anyList, reverseL, lenKey, escStr, splitOnChar, splitLast
}

-- A Product element lists every axis of its label's declared schema, in
-- declaration order, each at its own value or its top. The element carries
-- its domain: its first axis is the one a bare string lifts into, and two
-- Products are elements of one domain only when their schemas agree
-- (`domainKey`).
--
-- `PPath` is a Prefix element of a path label, a built-in label whose runtime
-- resolves a path with the file system (`FileRead`, `FileWrite`): its order
-- compares lexically normalized paths (`pathKey`), where `PPrefix`'s compares
-- text. Both
-- are one domain (`domainKey`); where they meet, the covering side's order
-- decides.
public export data Param =
  | PUnit
  | PPrefix (Option String)
  | PPath (Option String)
  | PSet (Option (List String))
  | PProduct (List (String, Param))

-- Canonical form of a parameter. The empty prefix denotes the Prefix domain's
-- top: `""` is a prefix of every path, so its join with any prefix is top and
-- top must cover it. One representation keeps join, coverage, rendering and a
-- solver's covered-atom skip in agreement; a producer that abstracts a value
-- to `""` builds the top parameter through this function. A path element
-- keeps its spelling, which the runtime resolves; it is compared, joined and
-- rendered in its append form (`pathSpelling`).
export
canonParam : Param -> Param
canonParam (PPrefix (Some s)) =
  if s == "" then PPrefix None else PPrefix (Some s)
canonParam (PPath (Some s)) = if s == "" then PPath None else PPath (Some s)
canonParam (PProduct ax) = productNorm ax
canonParam p = p

-- A Product's top is its schema with every axis at its own top.
export
subTopOf : Param -> Param
subTopOf (PPrefix _) = PPrefix None
subTopOf (PPath _) = PPath None
subTopOf (PSet _) = PSet None
subTopOf (PProduct ax) = PProduct (map (a => (fst a, subTopOf (snd a))) ax)
subTopOf _ = PUnit

-- The schema's primary axis lifted from a bare literal: a Prefix axis takes
-- the pattern, a Set axis the singleton; a Product with no declared schema
-- has no primary axis and the literal is the top.
export
productPrimaryLift : List (String, Param) -> String -> Param
productPrimaryLift [] _ = PProduct []
productPrimaryLift ((name, top) :: rest) s =
  let others = map (a => (fst a, subTopOf (snd a))) rest
  match top
    PPrefix _ => productNorm ((name, PPrefix (Some s)) :: others)
    PSet _ => productNorm ((name, PSet (Some [s])) :: others)
    _ => subTopOf (PProduct ((name, top) :: rest))

-- A written product as an element of [schema]: every declared axis, in
-- declaration order, at the value written for it or at its top.
export
productOver : List (String, Param) -> List (String, Param) -> Param
productOver schema written = productNorm (map (axisOver written) schema)

axisOver : List (String, Param) -> (String, Param) -> (String, Param)
axisOver written (name, top) = match lookupAxis name written
  Some PUnit => (name, subTopOf top)
  Some v => (name, v)
  None => (name, subTopOf top)

-- The element a value denotes once an unknown suffix is appended to it. A
-- pattern already admits every extension; an exact element becomes the
-- pattern it begins; a Set member becomes an unknown member, the top. In a
-- Product only the primary axis, its first, the one a string lifts into, is
-- extended.
export
extendParam : Param -> Param
extendParam p = match canonParam p
  PPrefix (Some s) =>
    if isPrefixPattern s then PPrefix (Some s) else PPrefix (Some (s ++ "*"))
  PPath (Some s) =>
    if isPrefixPattern s then
      PPath (Some s)
    else
      canonParam (PPath (Some (s ++ "*")))
  PProduct ((name, v) :: rest) => productNorm ((name, extendParam v) :: rest)
  q => subTopOf q

-- The element a value denotes once a known suffix is appended: an exact
-- element grows by the suffix, a pattern already admits it, and a Set member
-- becomes an unknown member.
export
appendParam : String -> Param -> Param
appendParam suffix p = match canonParam p
  PPrefix (Some s) =>
    if isPrefixPattern s then
      PPrefix (Some s)
    else
      canonParam (PPrefix (Some (s ++ suffix)))
  PPath (Some s) =>
    if isPrefixPattern s then
      PPath (Some s)
    else
      canonParam (PPath (Some (s ++ suffix)))
  PProduct ((name, v) :: rest) =>
    productNorm ((name, appendParam suffix v) :: rest)
  q => subTopOf q

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
-- is `"a.com*"`, never the bare `"a.com"`, which names one exact element and
-- is not a cover of the two). An empty
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
djoinN (PPath None) _ = PPath None
djoinN _ (PPath None) = PPath None
djoinN (PPath (Some a)) (PPath (Some b)) = pathJoin a b
djoinN (PPath (Some a)) (PPrefix (Some b)) = pathJoin a b
djoinN (PPrefix (Some a)) (PPath (Some b)) = pathJoin a b
djoinN (PSet None) _ = PSet None
djoinN _ (PSet None) = PSet None
djoinN (PSet (Some a)) (PSet (Some b)) =
  let u = sortUniqS (a ++ b)
  if listLen u > setCardCap then PSet None else PSet (Some u)
djoinN (p@(PProduct ax)) (q@(PProduct bx)) =
  if domainKey p == domainKey q then
    productNorm (map (joinAxis bx) ax)
  else
    subTopOf p
-- Elements of different domains (a Prefix against a Set, on a label or one
-- of a Product's axes, or Products of two schemas) have no join but the
-- whole domain.
djoinN p _ = subTopOf p

-- The elements a join of constants denotes, in one canonical form that
-- depends only on what they admit, never on the order they were written or
-- joined in:
--   * Set members are one set, their union: the Set join is exact.
--   * Prefix patterns are the maximal ones: a pattern another covers is
--     dropped, and the rest stay separate, so `"a.com/*"` beside
--     `"b.com/*"` admits those two hosts and nothing else.
--   * Products: a tuple another covers is dropped, and the rest are grouped
--     along one Set axis, the last by name among them: tuples written equal
--     on every other axis share one set of that axis's members, less those a
--     covering group already holds. `Host="a.com/*" Method={"GET"}` beside
--     the same host with `{"POST"}` is one tuple with both; beside
--     `Host="b.com/*"` it stays two, since their pointwise join would admit
--     POST to a.com. The form depends on the elements, not their order; two
--     spellings of one set may differ (`X={"1","2"}` against `X={"1"}` and
--     `X={"2"}`), which coverage in both directions still finds equal.
--   * Elements of different domains have no join: an authority that mixes
--     them is the whole domain, never one of its elements with the others
--     dropped.
-- Nothing is folded wider: a set of any size stays exact. Only a written
-- bound is held to `setCardCap` (`writtenSetProblem`), and only a value's
-- abstraction is widened past it (`authWidenValue`).
export
dantichain : List Param -> List Param
dantichain ps =
  let cs = map canonParam ps
  if anyList isSubTop cs || not (sameShape cs) then
    [subTopOf (headParam cs)]
  else match cs
    (PSet _) :: _ => [PSet (Some (sortUniqS (flatMap setMembers cs)))]
    (PPrefix _) :: _ =>
      if anyList isPathParam cs then
        sortParams (maximalPaths cs)
      else
        sortParams (maximalPrefixes cs)
    (PPath _) :: _ => sortParams (maximalPaths cs)
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

-- Products grouped along the last Set axis by name (see `dantichain`).
canonProducts : List Param -> List Param
canonProducts ps =
  let kept = maximalOf ps
  match lastSetAxis kept
    None => kept
    Some axis =>
      let groups = fold (acc p => addGroup axis p acc) [] kept
      flatMap (rebuildGroup axis groups) groups

-- All elements are of one domain.
sameShape : List Param -> Bool
sameShape [] = True
sameShape (p :: ps) = allList (q => domainKey q == domainKey p) ps

-- The domain an element belongs to: its shape, and for a Product its schema,
-- the axes in order with each axis's domain.
export
domainKey : Param -> String
domainKey PUnit = "u"
domainKey (PPrefix _) = "p"
domainKey (PPath _) = "p"
domainKey (PSet _) = "s"
domainKey (PProduct ax) =
  "x("
    ++ joinWith ";" (map (a => lenKey (fst a) ++ domainKey (snd a)) ax)
    ++ ")"

-- A group: its other axes (as a key that cannot collide, and as axes), its
-- members on the regroup axis, `None` for the whole axis, and the axes of
-- its first tuple, in schema order, that it is rebuilt in.
data PGroup =
  | PGroup String (List (String, Param)) (Option (List String)) (List (String, Param))

addGroup : String -> Param -> List PGroup -> List PGroup
addGroup axis p gs =
  let others = otherAxes axis p
  let key = axesKey others
  let members = axisMembers axis p
  match gs
    [] => [PGroup key others members (productAxes p)]
    (PGroup k o ms t) :: rest =>
      if k == key then
        PGroup k o (unionMembers ms members) t :: rest
      else
        PGroup k o ms t :: addGroup axis p rest

productAxes : Param -> List (String, Param)
productAxes (PProduct ax) = ax
productAxes _ = []

-- [axes] with the axis [name] set to [v], in place.
withAxis : String -> Param -> List (String, Param) -> List (String, Param)
withAxis name v axes = map (a => if fst a == name then (name, v) else a) axes

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
paramKey (PPath (Some s)) = "f" ++ lenKey s
paramKey (PPath None) = "F"
paramKey (PSet (Some xs)) = "s" ++ joinWith "" (map lenKey xs)
paramKey (PSet None) = "S"
paramKey (PProduct ax) = "x(" ++ axesKey ax ++ ")"
paramKey PUnit = "u"

-- A group less the members a covering group holds: another group whose
-- other axes cover this one's covers each member they share, and the whole
-- group if its members are the whole axis.
rebuildGroup : String -> List PGroup -> PGroup -> List Param
rebuildGroup axis gs (PGroup key others members template) =
  let coverers =
    filterList
      (g => match g
        PGroup k o _ _ =>
          k /= key && dsubN (productNorm others) (productNorm o))
      gs
  if anyList (g => groupMembersOf g == None) coverers then
    []
  else match members
    None => [productNorm (withAxis axis (PSet None) template)]
    Some xs =>
      let taken = flatMap (g => optionOr [] (groupMembersOf g)) coverers
      match filterList (x => not (contains x taken)) (sortUniqS xs)
        [] => []
        left => [productNorm (withAxis axis (PSet (Some left)) template)]

groupMembersOf : PGroup -> Option (List String)
groupMembersOf (PGroup _ _ ms _) = ms

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

-- One axis of a join of two elements of one schema.
joinAxis : List (String, Param) -> (String, Param) -> (String, Param)
joinAxis bx (name, pa) = match lookupAxis name bx
  Some pb => (name, djoinN pa pb)
  None => (name, subTopOf pa)

-- A Product with each axis's value canonical, in place: the axes stay the
-- schema's, tops included.
export
productNorm : List (String, Param) -> Param
productNorm axes = PProduct (map (a => (fst a, canonParam (snd a))) axes)

export
isSubTop : Param -> Bool
isSubTop (PPrefix None) = True
isSubTop (PPath None) = True
isSubTop (PSet None) = True
isSubTop (PProduct ax) = allList (a => isSubTop (snd a)) ax
isSubTop PUnit = True
isSubTop _ = False

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
drenderN (PPrefix (Some s)) = " " ++ quoteStr s
drenderN (PPath None) = ""
drenderN (PPath (Some s)) = " " ++ quoteStr (pathSpelling s)
drenderN (PSet None) = ""
drenderN (PSet (Some xs)) = " {" ++ joinWith ", " (map quoteStr xs) ++ "}"
drenderN (PProduct ax) = match renderProductLit ax
  "" => ""
  r => " " ++ r

export
quoteStr : String -> String
quoteStr s = escStr s

-- A Product's axes as written: a top axis is spelled by leaving it out.
export
renderProductLit : List (String, Param) -> String
renderProductLit ax =
  joinWith " " (map renderAxis (filterList (a => not (isSubTop (snd a))) ax))

export
renderAxis : (String, Param) -> String
renderAxis (name, p) = "\{name}=\{renderAxisVal p}"

export
renderAxisVal : Param -> String
renderAxisVal (PPrefix (Some s)) = quoteStr s
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
dsubN _ (PPath None) = True
dsubN (PPath (Some a)) (PPath (Some b)) = pathSub (pathKey a) (pathKey b)
dsubN (PPrefix (Some a)) (PPath (Some b)) = pathSub (pathKey a) (pathKey b)
dsubN (PPath (Some a)) (PPrefix (Some b)) =
  dsubN (PPrefix (Some a)) (PPrefix (Some b))
dsubN _ (PSet None) = True
dsubN (PSet (Some a)) (PSet (Some b)) = subsetStr a b
dsubN (PSet None) (PSet (Some _)) = False
dsubN _ (PProduct []) = True
dsubN (p@(PProduct ax)) (q@(PProduct bx)) =
  domainKey p == domainKey q && allList (axisSub ax) bx
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

-- ── Path elements ──────────────────────────────────────────────────────────
-- A path label's runtime confines each call's path against that call's own
-- grant, resolving both with the file system (EFFECTS-SEMANTICS §8); it never
-- re-checks the declared bound. The order here is lexical: empty and `.`
-- components are dropped, a `..` at the root of an absolute path stays at the
-- root, and a relative path keeps a `..` that climbs above the working
-- directory as a leading component, which no path inside the working
-- directory has. A pattern's text after its last `/` is read as written, as
-- the runtime reads it, and `*` alone admits every path.
--
-- A `..` that follows a named component is not resolved: a symlink can make
-- `x/..` any directory at all, so an element that pops a named component lies
-- only within itself and the whole domain, and only its own spelling lies
-- within it.
--
-- An element keeps the spelling it was written or derived with, which a
-- grant passes to the runtime to resolve, and is rendered and told apart by
-- its append form: every component before the last `/` normalized, the last
-- as written. A suffix appended later extends the last component (`"data/"`
-- and `"data"` are one path, and not one prefix), so two spellings with one
-- append form have the same extensions, and only the order reads the
-- normalized form (`pathKey`). A pattern's append form is its normalized form.
data PathKey =
  | KAll
  | KExact Bool (List String)
  | KPattern Bool (List String) String
  | KPopped String

-- The append form of a path element's spelling.
export
pathSpelling : String -> String
pathSpelling s =
  if isPrefixPattern s then
    let c = prefixConcrete s
    if c == "" then s else appendForm c ++ "*"
  else
    appendForm s

appendForm : String -> String
appendForm c = match splitLast (splitOnChar '/' c)
  Some ([], last) => last
  Some (dir, last) =>
    let abs = startsWith "/" c
    dirSpelling abs (lexicalPath abs dir) last ++ last
  None => c

dirSpelling : Bool -> List String -> String -> String
dirSpelling True [] _ = "/"
dirSpelling True d _ = "/" ++ joinWith "/" d ++ "/"
dirSpelling False [] last = if last == "" then "./" else ""
dirSpelling False d _ = joinWith "/" d ++ "/"

-- The normalized form of a path element's spelling. A popping element is
-- told apart only by its spelling, pattern or exact.
pathKey : String -> PathKey
pathKey s =
  if isPrefixPattern s then
    let c = prefixConcrete s
    let abs = startsWith "/" c
    if c == "" then
      KAll
    else match splitLast (splitOnChar '/' c)
      Some (dir, stem) =>
        let d = lexicalPath abs dir
        if popsNamed False d then
          KPopped ("p" ++ pathSpelling s)
        else
          KPattern abs d stem
      None => KAll
  else
    let abs = startsWith "/" s
    let xs = lexicalPath abs (splitOnChar '/' s)
    if popsNamed False xs then
      KPopped "e\{rootSlash abs}\{joinWith "/" xs}"
    else
      KExact abs xs

rootSlash : Bool -> String
rootSlash abs = if abs then "/" else ""

lexicalPath : Bool -> List String -> List String
lexicalPath abs parts = reverseL (fold (lexicalStep abs) [] parts)

lexicalStep : Bool -> List String -> String -> List String
lexicalStep abs acc c
  | c == "" || c == "." = acc
  | c == ".." && abs && isEmptyList acc = acc
  | otherwise = c :: acc

isEmptyList : List a -> Bool
isEmptyList [] = True
isEmptyList _ = False

-- Whether normalized components hold a `..` after a named component.
popsNamed : Bool -> List String -> Bool
popsNamed _ [] = False
popsNamed named (c :: cs) =
  if c == ".." then named || popsNamed named cs else popsNamed True cs

-- Coverage of normalized forms: an exact path admits itself; a pattern admits
-- its directory when its stem is empty, and every path under the directory
-- whose next component begins with the stem, never a `..` that climbs out of
-- it. A relative path is never compared with an absolute one: which one the
-- working directory makes it is a runtime fact.
pathSub : PathKey -> PathKey -> Bool
pathSub _ KAll = True
pathSub KAll _ = False
pathSub (KPopped a) (KPopped b) = a == b
pathSub (KPopped _) _ = False
pathSub _ (KPopped _) = False
pathSub (KExact a xs) (KExact b ys) = a == b && xs == ys
pathSub (KExact a xs) (KPattern b dir stem) =
  a == b && (xs == dir && stem == "" || underDir dir stem xs)
pathSub (KPattern _ _ _) (KExact _ _) = False
pathSub (KPattern a d1 s1) (KPattern b d2 s2) =
  a == b && (d1 == d2 && startsWith s2 s1 || underDir d2 s2 d1)

underDir : List String -> String -> List String -> Bool
underDir dir stem xs = match dropListPrefix dir xs
  Some (next :: _) => next /= ".." && startsWith stem next
  _ => False

dropListPrefix : List String -> List String -> Option (List String)
dropListPrefix [] xs = Some xs
dropListPrefix (d :: ds) (x :: xs) =
  if d == x then dropListPrefix ds xs else None
dropListPrefix _ [] = None

-- The join of two path elements: the pattern their common text begins, when
-- it covers both, else the domain's top. Only a value's abstraction past
-- `setCardCap` folds elements by the join (`authWidenValue`), and a later
-- suffix extends the pattern, so it is formed from the text both begin with.
pathJoin : String -> String -> Param
pathJoin a b =
  let ca = prefixConcrete (pathSpelling a)
  let cb = prefixConcrete (pathSpelling b)
  let k = commonPrefixLen ca cb 0
  if pathSpelling a == pathSpelling b then
    PPath (Some a)
  else if k == 0 then
    PPath None
  else
    let joined = pathSpelling (stringSlice 0 k ca ++ "*")
    let jk = pathKey joined
    if pathSub (pathKey a) jk && pathSub (pathKey b) jk then
      PPath (Some joined)
    else
      PPath None

isPathParam : Param -> Bool
isPathParam (PPath _) = True
isPathParam _ = False

-- The maximal elements of a join that holds a path element. Two spellings of
-- one exact path are both kept unless they are one append form, since a
-- suffix appended later extends each differently (`pathSpelling`). Path
-- elements alone are swept in order of key text (`pathKeyText`); a join that
-- also holds a text element compares every pair, since there each pair takes
-- its covering side's order.
maximalPaths : List Param -> List Param
maximalPaths ps =
  if allList isPathParam ps then
    pathSweep (sortByKey pathEntryOrder (map pathEntry ps)) [] None []
  else
    fold (acc p => keepMaximalPath p acc) [] ps

keepMaximalPath : Param -> List Param -> List Param
keepMaximalPath p acc =
  if anyList (q => pathCovers q p) acc then
    acc
  else
    p :: filterList (q => not (pathCovers p q)) acc

pathCovers : Param -> Param -> Bool
pathCovers q p =
  dsubN p q && (paramSpelling p == paramSpelling q || not (dsubN q p))

paramSpelling : Param -> String
paramSpelling (PPrefix (Some s)) = s
paramSpelling (PPath (Some s)) = pathSpelling s
paramSpelling _ = ""

-- A path element for the sweep: its key's text, whether it can cover another
-- element, its key, its append form, and the element.
data PathEntry = PathEntry String Bool PathKey String Param

pathEntry : Param -> PathEntry
pathEntry (p@(PPath (Some s))) =
  let k = pathKey s
  PathEntry (pathKeyText k) (keyCoversOthers k) k (pathSpelling s) p
pathEntry p = PathEntry "" True KAll "*" p

-- A key's text begins with the text of every key that covers it (`pathSub`),
-- so the elements a key covers follow it consecutively in text order.
-- Components never hold `/`, which separates them.
pathKeyText : PathKey -> String
pathKeyText KAll = ""
pathKeyText (KExact abs xs) = "\{rootTag abs}\{componentsText xs}/"
pathKeyText (KPattern abs dir stem) =
  "\{rootTag abs}\{componentsText dir}/\{stem}"
pathKeyText (KPopped t) = "x" ++ t

rootTag : Bool -> String
rootTag abs = if abs then "a" else "r"

componentsText : List String -> String
componentsText xs = joinWith "" (map ("/" ++ _) xs)

keyCoversOthers : PathKey -> Bool
keyCoversOthers KAll = True
keyCoversOthers (KPattern _ _ _) = True
keyCoversOthers _ = False

-- By key text; of one text, an element that can cover before one that
-- cannot, then by append form, so repeats are adjacent.
pathEntryOrder : PathEntry -> PathEntry -> Bool
pathEntryOrder (PathEntry a ca _ sa _) (PathEntry b cb _ sb _) =
  match stringCompare a b
    Lt => True
    Gt => False
    Eq => if ca == cb then stringCompare sa sb /= Gt else ca

-- One pass in key-text order. The open covering elements form a chain, each
-- one's text beginning the next's; an element is dropped when one of them
-- covers it, or when it repeats the last kept non-covering element's key text
-- and append form.
pathSweep : List PathEntry ->
  List PathEntry ->
  Option (String, String) ->
  List Param ->
  List Param
pathSweep [] _ _ kept = kept
pathSweep ((e@(PathEntry t covers _ sp p)) :: rest) open last kept =
  let still = dropOpenNotPrefix t open
  if anyList (entryCovers e) still || last == Some (t, sp) then
    pathSweep rest still last kept
  else if covers then
    pathSweep rest (e :: still) last (p :: kept)
  else
    pathSweep rest still (Some (t, sp)) (p :: kept)

dropOpenNotPrefix : String -> List PathEntry -> List PathEntry
dropOpenNotPrefix _ [] = []
dropOpenNotPrefix t ((o@(PathEntry ot _ _ _ _)) :: os) =
  if startsWith ot t then o :: os else dropOpenNotPrefix t os

-- Whether the open element [q] covers [e]: it contains it, and not only as
-- another spelling of one path.
entryCovers : PathEntry -> PathEntry -> Bool
entryCovers (PathEntry _ _ k sp _) (PathEntry _ _ qk qsp _) =
  pathSub k qk && (sp == qsp || not (pathSub qk k))

-- Whether a path element's normalized form lies above the working directory:
-- a relative path that begins by climbing out of it.
export
pathClimbs : Param -> Bool
pathClimbs (PPath (Some s)) = match pathKey s
  KExact False (".." :: _) => True
  KPattern False (".." :: _) _ => True
  _ => False
pathClimbs _ = False

-- A Prefix term read at a label of [top]'s domain takes that label's order: a
-- constant written without a label (a qualifier's literal) becomes a path
-- element at a path label.
export
retagParam : Param -> Param -> Param
retagParam (PPath _) (PPrefix (Some s)) = canonParam (PPath (Some s))
retagParam _ p = p
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false) (mem "anyList" false) (mem "reverseL" false) (mem "lenKey" false) (mem "escStr" false) (mem "splitOnChar" false) (mem "splitLast" false))))
(DData Public "Param" () ((variant "PUnit" (ConPos)) (variant "PPrefix" (ConPos (TyApp (TyCon "Option") (TyCon "String")))) (variant "PPath" (ConPos (TyApp (TyCon "Option") (TyCon "String")))) (variant "PSet" (ConPos (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))) (variant "PProduct" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))) ())
(DTypeSig true "canonParam" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "canonParam" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "canonParam" ((PCon "PPath" (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "PPath") (EVar "None")) (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "canonParam" ((PCon "PProduct" (PVar "ax"))) (EApp (EVar "productNorm") (EVar "ax")))
(DFunDef false "canonParam" ((PVar "p")) (EVar "p"))
(DTypeSig true "subTopOf" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "subTopOf" ((PCon "PPrefix" PWild)) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PPath" PWild)) (EApp (EVar "PPath") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PSet" PWild)) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PProduct" (PVar "ax"))) (EApp (EVar "PProduct") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "subTopOf") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax"))))
(DFunDef false "subTopOf" (PWild) (EVar "PUnit"))
(DTypeSig true "productPrimaryLift" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyCon "Param"))))
(DFunDef false "productPrimaryLift" ((PList) PWild) (EApp (EVar "PProduct") (EListLit)))
(DFunDef false "productPrimaryLift" ((PCons (PTuple (PVar "name") (PVar "top")) (PVar "rest")) (PVar "s")) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "subTopOf") (EApp (EVar "snd") (EVar "a")))))) (EVar "rest"))) (DoExpr (EMatch (EVar "top") (arm (PCon "PPrefix" PWild) () (EApp (EVar "productNorm") (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))) (EVar "others")))) (arm (PCon "PSet" PWild) () (EApp (EVar "productNorm") (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "s"))))) (EVar "others")))) (arm PWild () (EApp (EVar "subTopOf") (EApp (EVar "PProduct") (EBinOp "::" (ETuple (EVar "name") (EVar "top")) (EVar "rest")))))))))
(DTypeSig true "productOver" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Param"))))
(DFunDef false "productOver" ((PVar "schema") (PVar "written")) (EApp (EVar "productNorm") (EApp (EApp (EVar "map") (EApp (EVar "axisOver") (EVar "written"))) (EVar "schema"))))
(DTypeSig false "axisOver" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "axisOver" ((PVar "written") (PTuple (PVar "name") (PVar "top"))) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "written")) (arm (PCon "Some" (PCon "PUnit")) () (ETuple (EVar "name") (EApp (EVar "subTopOf") (EVar "top")))) (arm (PCon "Some" (PVar "v")) () (ETuple (EVar "name") (EVar "v"))) (arm (PCon "None") () (ETuple (EVar "name") (EApp (EVar "subTopOf") (EVar "top"))))))
(DTypeSig true "extendParam" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "extendParam" ((PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (ELit (LString "*"))))))) (arm (PCon "PPath" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPath") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (ELit (LString "*")))))))) (arm (PCon "PProduct" (PCons (PTuple (PVar "name") (PVar "v")) (PVar "rest"))) () (EApp (EVar "productNorm") (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "extendParam") (EVar "v"))) (EVar "rest")))) (arm (PVar "q") () (EApp (EVar "subTopOf") (EVar "q")))))
(DTypeSig true "appendParam" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "appendParam" ((PVar "suffix") (PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (EVar "suffix"))))))) (arm (PCon "PPath" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPath") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (EVar "suffix"))))))) (arm (PCon "PProduct" (PCons (PTuple (PVar "name") (PVar "v")) (PVar "rest"))) () (EApp (EVar "productNorm") (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "appendParam") (EVar "suffix")) (EVar "v"))) (EVar "rest")))) (arm (PVar "q") () (EApp (EVar "subTopOf") (EVar "q")))))
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
(DFunDef false "djoinN" ((PCon "PPath" (PCon "None")) PWild) (EApp (EVar "PPath") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PPath" (PCon "None"))) (EApp (EVar "PPath") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PPath" (PCon "Some" (PVar "a"))) (PCon "PPath" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "pathJoin") (EVar "a")) (EVar "b")))
(DFunDef false "djoinN" ((PCon "PPath" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "pathJoin") (EVar "a")) (EVar "b")))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPath" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "pathJoin") (EVar "a")) (EVar "b")))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "None")) PWild) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PSet" (PCon "None"))) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EBlock (DoLet false false (PVar "u") (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "a") (EVar "b")))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "u")) (EVar "setCardCap")) (EApp (EVar "PSet") (EVar "None")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "u")))))))
(DFunDef false "djoinN" ((PAs "p" (PCon "PProduct" (PVar "ax"))) (PAs "q" (PCon "PProduct" (PVar "bx")))) (EIf (EBinOp "==" (EApp (EVar "domainKey") (EVar "p")) (EApp (EVar "domainKey") (EVar "q"))) (EApp (EVar "productNorm") (EApp (EApp (EVar "map") (EApp (EVar "joinAxis") (EVar "bx"))) (EVar "ax"))) (EApp (EVar "subTopOf") (EVar "p"))))
(DFunDef false "djoinN" ((PVar "p") PWild) (EApp (EVar "subTopOf") (EVar "p")))
(DTypeSig true "dantichain" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "dantichain" ((PVar "ps")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "map") (EVar "canonParam")) (EVar "ps"))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EVar "anyList") (EVar "isSubTop")) (EVar "cs")) (EApp (EVar "not") (EApp (EVar "sameShape") (EVar "cs")))) (EListLit (EApp (EVar "subTopOf") (EApp (EVar "headParam") (EVar "cs")))) (EMatch (EVar "cs") (arm (PCons (PCon "PSet" PWild) PWild) () (EListLit (EApp (EVar "PSet") (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EApp (EApp (EVar "flatMap") (EVar "setMembers")) (EVar "cs"))))))) (arm (PCons (PCon "PPrefix" PWild) PWild) () (EIf (EApp (EApp (EVar "anyList") (EVar "isPathParam")) (EVar "cs")) (EApp (EVar "sortParams") (EApp (EVar "maximalPaths") (EVar "cs"))) (EApp (EVar "sortParams") (EApp (EVar "maximalPrefixes") (EVar "cs"))))) (arm (PCons (PCon "PPath" PWild) PWild) () (EApp (EVar "sortParams") (EApp (EVar "maximalPaths") (EVar "cs")))) (arm (PCons (PCon "PProduct" PWild) PWild) () (EApp (EVar "sortParams") (EApp (EVar "canonProducts") (EVar "cs")))) (arm (PList) () (EListLit)) (arm PWild () (EApp (EVar "sortParams") (EApp (EVar "maximalOf") (EVar "cs")))))))))
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
(DFunDef false "canonProducts" ((PVar "ps")) (EBlock (DoLet false false (PVar "kept") (EApp (EVar "maximalOf") (EVar "ps"))) (DoExpr (EMatch (EApp (EVar "lastSetAxis") (EVar "kept")) (arm (PCon "None") () (EVar "kept")) (arm (PCon "Some" (PVar "axis")) () (EBlock (DoLet false false (PVar "groups") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EApp (EVar "addGroup") (EVar "axis")) (EVar "p")) (EVar "acc")))) (EListLit)) (EVar "kept"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "rebuildGroup") (EVar "axis")) (EVar "groups"))) (EVar "groups")))))))))
(DTypeSig false "sameShape" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Bool")))
(DFunDef false "sameShape" ((PList)) (EVar "True"))
(DFunDef false "sameShape" ((PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EVar "allList") (ELam ((PVar "q")) (EBinOp "==" (EApp (EVar "domainKey") (EVar "q")) (EApp (EVar "domainKey") (EVar "p"))))) (EVar "ps")))
(DTypeSig true "domainKey" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "domainKey" ((PCon "PUnit")) (ELit (LString "u")))
(DFunDef false "domainKey" ((PCon "PPrefix" PWild)) (ELit (LString "p")))
(DFunDef false "domainKey" ((PCon "PPath" PWild)) (ELit (LString "p")))
(DFunDef false "domainKey" ((PCon "PSet" PWild)) (ELit (LString "s")))
(DFunDef false "domainKey" ((PCon "PProduct" (PVar "ax"))) (EBinOp "++" (EBinOp "++" (ELit (LString "x(")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EBinOp "++" (EApp (EVar "lenKey") (EApp (EVar "fst") (EVar "a"))) (EApp (EVar "domainKey") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax")))) (ELit (LString ")"))))
(DData Private "PGroup" () ((variant "PGroup" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))) ())
(DTypeSig false "addGroup" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "PGroup")) (TyApp (TyCon "List") (TyCon "PGroup"))))))
(DFunDef false "addGroup" ((PVar "axis") (PVar "p") (PVar "gs")) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "otherAxes") (EVar "axis")) (EVar "p"))) (DoLet false false (PVar "key") (EApp (EVar "axesKey") (EVar "others"))) (DoLet false false (PVar "members") (EApp (EApp (EVar "axisMembers") (EVar "axis")) (EVar "p"))) (DoExpr (EMatch (EVar "gs") (arm (PList) () (EListLit (EApp (EApp (EApp (EApp (EVar "PGroup") (EVar "key")) (EVar "others")) (EVar "members")) (EApp (EVar "productAxes") (EVar "p"))))) (arm (PCons (PCon "PGroup" (PVar "k") (PVar "o") (PVar "ms") (PVar "t")) (PVar "rest")) () (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "PGroup") (EVar "k")) (EVar "o")) (EApp (EApp (EVar "unionMembers") (EVar "ms")) (EVar "members"))) (EVar "t")) (EVar "rest")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "PGroup") (EVar "k")) (EVar "o")) (EVar "ms")) (EVar "t")) (EApp (EApp (EApp (EVar "addGroup") (EVar "axis")) (EVar "p")) (EVar "rest")))))))))
(DTypeSig false "productAxes" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "productAxes" ((PCon "PProduct" (PVar "ax"))) (EVar "ax"))
(DFunDef false "productAxes" (PWild) (EListLit))
(DTypeSig false "withAxis" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))))
(DFunDef false "withAxis" ((PVar "name") (PVar "v") (PVar "axes")) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EIf (EBinOp "==" (EApp (EVar "fst") (EVar "a")) (EVar "name")) (ETuple (EVar "name") (EVar "v")) (EVar "a")))) (EVar "axes")))
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
(DFunDef false "paramKey" ((PCon "PPath" (PCon "Some" (PVar "s")))) (EBinOp "++" (ELit (LString "f")) (EApp (EVar "lenKey") (EVar "s"))))
(DFunDef false "paramKey" ((PCon "PPath" (PCon "None"))) (ELit (LString "F")))
(DFunDef false "paramKey" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EBinOp "++" (ELit (LString "s")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "lenKey")) (EVar "xs")))))
(DFunDef false "paramKey" ((PCon "PSet" (PCon "None"))) (ELit (LString "S")))
(DFunDef false "paramKey" ((PCon "PProduct" (PVar "ax"))) (EBinOp "++" (EBinOp "++" (ELit (LString "x(")) (EApp (EVar "axesKey") (EVar "ax"))) (ELit (LString ")"))))
(DFunDef false "paramKey" ((PCon "PUnit")) (ELit (LString "u")))
(DTypeSig false "rebuildGroup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PGroup")) (TyFun (TyCon "PGroup") (TyApp (TyCon "List") (TyCon "Param"))))))
(DFunDef false "rebuildGroup" ((PVar "axis") (PVar "gs") (PCon "PGroup" (PVar "key") (PVar "others") (PVar "members") (PVar "template"))) (EBlock (DoLet false false (PVar "coverers") (EApp (EApp (EVar "filterList") (ELam ((PVar "g")) (EMatch (EVar "g") (arm (PCon "PGroup" (PVar "k") (PVar "o") PWild PWild) () (EBinOp "&&" (EBinOp "/=" (EVar "k") (EVar "key")) (EApp (EApp (EVar "dsubN") (EApp (EVar "productNorm") (EVar "others"))) (EApp (EVar "productNorm") (EVar "o")))))))) (EVar "gs"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "g")) (EBinOp "==" (EApp (EVar "groupMembersOf") (EVar "g")) (EVar "None")))) (EVar "coverers")) (EListLit) (EMatch (EVar "members") (arm (PCon "None") () (EListLit (EApp (EVar "productNorm") (EApp (EApp (EApp (EVar "withAxis") (EVar "axis")) (EApp (EVar "PSet") (EVar "None"))) (EVar "template"))))) (arm (PCon "Some" (PVar "xs")) () (EBlock (DoLet false false (PVar "taken") (EApp (EApp (EVar "flatMap") (ELam ((PVar "g")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EVar "groupMembersOf") (EVar "g"))))) (EVar "coverers"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "x")) (EVar "taken"))))) (EApp (EVar "sortUniqS") (EVar "xs"))) (arm (PList) () (EListLit)) (arm (PVar "left") () (EListLit (EApp (EVar "productNorm") (EApp (EApp (EApp (EVar "withAxis") (EVar "axis")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "left")))) (EVar "template"))))))))))))))
(DTypeSig false "groupMembersOf" (TyFun (TyCon "PGroup") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "groupMembersOf" ((PCon "PGroup" PWild PWild (PVar "ms") PWild)) (EVar "ms"))
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
(DTypeSig false "joinAxis" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "joinAxis" ((PVar "bx") (PTuple (PVar "name") (PVar "pa"))) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "bx")) (arm (PCon "Some" (PVar "pb")) () (ETuple (EVar "name") (EApp (EApp (EVar "djoinN") (EVar "pa")) (EVar "pb")))) (arm (PCon "None") () (ETuple (EVar "name") (EApp (EVar "subTopOf") (EVar "pa"))))))
(DTypeSig true "productNorm" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Param")))
(DFunDef false "productNorm" ((PVar "axes")) (EApp (EVar "PProduct") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "canonParam") (EApp (EVar "snd") (EVar "a")))))) (EVar "axes"))))
(DTypeSig true "isSubTop" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "isSubTop" ((PCon "PPrefix" (PCon "None"))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PPath" (PCon "None"))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EVar "allList") (ELam ((PVar "a")) (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "a"))))) (EVar "ax")))
(DFunDef false "isSubTop" ((PCon "PUnit")) (EVar "True"))
(DFunDef false "isSubTop" (PWild) (EVar "False"))
(DTypeSig true "setCardCap" (TyCon "Int"))
(DFunDef false "setCardCap" () (ELit (LInt 16)))
(DTypeSig true "commonPrefixLen" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "commonPrefixLen" ((PVar "a") (PVar "b") (PVar "i")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "a"))) (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "b")))) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "a")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "b"))) (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i"))))
(DTypeSig true "drender" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "drender" ((PVar "p")) (EApp (EVar "drenderN") (EApp (EVar "canonParam") (EVar "p"))))
(DTypeSig true "drenderN" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "drenderN" ((PCon "PUnit")) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PPrefix" (PCon "None"))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EBinOp "++" (ELit (LString " ")) (EApp (EVar "quoteStr") (EVar "s"))))
(DFunDef false "drenderN" ((PCon "PPath" (PCon "None"))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PPath" (PCon "Some" (PVar "s")))) (EBinOp "++" (ELit (LString " ")) (EApp (EVar "quoteStr") (EApp (EVar "pathSpelling") (EVar "s")))))
(DFunDef false "drenderN" ((PCon "PSet" (PCon "None"))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EBinOp "++" (EBinOp "++" (ELit (LString " {")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoteStr")) (EVar "xs")))) (ELit (LString "}"))))
(DFunDef false "drenderN" ((PCon "PProduct" (PVar "ax"))) (EMatch (EApp (EVar "renderProductLit") (EVar "ax")) (arm (PLit (LString "")) () (ELit (LString ""))) (arm (PVar "r") () (EBinOp "++" (ELit (LString " ")) (EVar "r")))))
(DTypeSig true "quoteStr" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteStr" ((PVar "s")) (EApp (EVar "escStr") (EVar "s")))
(DTypeSig true "renderProductLit" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "renderProductLit" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "renderAxis")) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax")))))
(DTypeSig true "renderAxis" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "renderAxis" ((PTuple (PVar "name") (PVar "p"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "="))) (EApp (EVar "display") (EApp (EVar "renderAxisVal") (EVar "p")))) (ELit (LString ""))))
(DTypeSig true "renderAxisVal" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "renderAxisVal" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EApp (EVar "quoteStr") (EVar "s")))
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
(DFunDef false "dsubN" (PWild (PCon "PPath" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PPath" (PCon "Some" (PVar "a"))) (PCon "PPath" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "pathSub") (EApp (EVar "pathKey") (EVar "a"))) (EApp (EVar "pathKey") (EVar "b"))))
(DFunDef false "dsubN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPath" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "pathSub") (EApp (EVar "pathKey") (EVar "a"))) (EApp (EVar "pathKey") (EVar "b"))))
(DFunDef false "dsubN" ((PCon "PPath" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "dsubN") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "a")))) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "b")))))
(DFunDef false "dsubN" (PWild (PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "subsetStr") (EVar "a")) (EVar "b")))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "None")) (PCon "PSet" (PCon "Some" PWild))) (EVar "False"))
(DFunDef false "dsubN" (PWild (PCon "PProduct" (PList))) (EVar "True"))
(DFunDef false "dsubN" ((PAs "p" (PCon "PProduct" (PVar "ax"))) (PAs "q" (PCon "PProduct" (PVar "bx")))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "domainKey") (EVar "p")) (EApp (EVar "domainKey") (EVar "q"))) (EApp (EApp (EVar "allList") (EApp (EVar "axisSub") (EVar "ax"))) (EVar "bx"))))
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
(DData Private "PathKey" () ((variant "KAll" (ConPos)) (variant "KExact" (ConPos (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))) (variant "KPattern" (ConPos (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))) (variant "KPopped" (ConPos (TyCon "String")))) ())
(DTypeSig true "pathSpelling" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "pathSpelling" ((PVar "s")) (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "prefixConcrete") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LString ""))) (EVar "s") (EBinOp "++" (EApp (EVar "appendForm") (EVar "c")) (ELit (LString "*")))))) (EApp (EVar "appendForm") (EVar "s"))))
(DTypeSig false "appendForm" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "appendForm" ((PVar "c")) (EMatch (EApp (EVar "splitLast") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "c"))) (arm (PCon "Some" (PTuple (PList) (PVar "last"))) () (EVar "last")) (arm (PCon "Some" (PTuple (PVar "dir") (PVar "last"))) () (EBlock (DoLet false false (PVar "abs") (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "c"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "dirSpelling") (EVar "abs")) (EApp (EApp (EVar "lexicalPath") (EVar "abs")) (EVar "dir"))) (EVar "last")) (EVar "last"))))) (arm (PCon "None") () (EVar "c"))))
(DTypeSig false "dirSpelling" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "dirSpelling" ((PCon "True") (PList) PWild) (ELit (LString "/")))
(DFunDef false "dirSpelling" ((PCon "True") (PVar "d") PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "/")) (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "d"))) (ELit (LString "/"))))
(DFunDef false "dirSpelling" ((PCon "False") (PList) (PVar "last")) (EIf (EBinOp "==" (EVar "last") (ELit (LString ""))) (ELit (LString "./")) (ELit (LString ""))))
(DFunDef false "dirSpelling" ((PCon "False") (PVar "d") PWild) (EBinOp "++" (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "d")) (ELit (LString "/"))))
(DTypeSig false "pathKey" (TyFun (TyCon "String") (TyCon "PathKey")))
(DFunDef false "pathKey" ((PVar "s")) (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "prefixConcrete") (EVar "s"))) (DoLet false false (PVar "abs") (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "c"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LString ""))) (EVar "KAll") (EMatch (EApp (EVar "splitLast") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "c"))) (arm (PCon "Some" (PTuple (PVar "dir") (PVar "stem"))) () (EBlock (DoLet false false (PVar "d") (EApp (EApp (EVar "lexicalPath") (EVar "abs")) (EVar "dir"))) (DoExpr (EIf (EApp (EApp (EVar "popsNamed") (EVar "False")) (EVar "d")) (EApp (EVar "KPopped") (EBinOp "++" (ELit (LString "p")) (EApp (EVar "pathSpelling") (EVar "s")))) (EApp (EApp (EApp (EVar "KPattern") (EVar "abs")) (EVar "d")) (EVar "stem")))))) (arm (PCon "None") () (EVar "KAll")))))) (EBlock (DoLet false false (PVar "abs") (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "s"))) (DoLet false false (PVar "xs") (EApp (EApp (EVar "lexicalPath") (EVar "abs")) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "s")))) (DoExpr (EIf (EApp (EApp (EVar "popsNamed") (EVar "False")) (EVar "xs")) (EApp (EVar "KPopped") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "e")) (EApp (EVar "display") (EApp (EVar "rootSlash") (EVar "abs")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "xs")))) (ELit (LString "")))) (EApp (EApp (EVar "KExact") (EVar "abs")) (EVar "xs")))))))
(DTypeSig false "rootSlash" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "rootSlash" ((PVar "abs")) (EIf (EVar "abs") (ELit (LString "/")) (ELit (LString ""))))
(DTypeSig false "lexicalPath" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lexicalPath" ((PVar "abs") (PVar "parts")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "fold") (EApp (EVar "lexicalStep") (EVar "abs"))) (EListLit)) (EVar "parts"))))
(DTypeSig false "lexicalStep" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lexicalStep" ((PVar "abs") (PVar "acc") (PVar "c")) (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LString ""))) (EBinOp "==" (EVar "c") (ELit (LString ".")))) (EVar "acc") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LString ".."))) (EVar "abs")) (EApp (EVar "isEmptyList") (EVar "acc"))) (EVar "acc") (EIf (EVar "otherwise") (EBinOp "::" (EVar "c") (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isEmptyList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isEmptyList" ((PList)) (EVar "True"))
(DFunDef false "isEmptyList" (PWild) (EVar "False"))
(DTypeSig false "popsNamed" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "popsNamed" (PWild (PList)) (EVar "False"))
(DFunDef false "popsNamed" ((PVar "named") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EVar "c") (ELit (LString ".."))) (EBinOp "||" (EVar "named") (EApp (EApp (EVar "popsNamed") (EVar "named")) (EVar "cs"))) (EApp (EApp (EVar "popsNamed") (EVar "True")) (EVar "cs"))))
(DTypeSig false "pathSub" (TyFun (TyCon "PathKey") (TyFun (TyCon "PathKey") (TyCon "Bool"))))
(DFunDef false "pathSub" (PWild (PCon "KAll")) (EVar "True"))
(DFunDef false "pathSub" ((PCon "KAll") PWild) (EVar "False"))
(DFunDef false "pathSub" ((PCon "KPopped" (PVar "a")) (PCon "KPopped" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "pathSub" ((PCon "KPopped" PWild) PWild) (EVar "False"))
(DFunDef false "pathSub" (PWild (PCon "KPopped" PWild)) (EVar "False"))
(DFunDef false "pathSub" ((PCon "KExact" (PVar "a") (PVar "xs")) (PCon "KExact" (PVar "b") (PVar "ys"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "==" (EVar "xs") (EVar "ys"))))
(DFunDef false "pathSub" ((PCon "KExact" (PVar "a") (PVar "xs")) (PCon "KPattern" (PVar "b") (PVar "dir") (PVar "stem"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "xs") (EVar "dir")) (EBinOp "==" (EVar "stem") (ELit (LString "")))) (EApp (EApp (EApp (EVar "underDir") (EVar "dir")) (EVar "stem")) (EVar "xs")))))
(DFunDef false "pathSub" ((PCon "KPattern" PWild PWild PWild) (PCon "KExact" PWild PWild)) (EVar "False"))
(DFunDef false "pathSub" ((PCon "KPattern" (PVar "a") (PVar "d1") (PVar "s1")) (PCon "KPattern" (PVar "b") (PVar "d2") (PVar "s2"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "d1") (EVar "d2")) (EApp (EApp (EVar "startsWith") (EVar "s2")) (EVar "s1"))) (EApp (EApp (EApp (EVar "underDir") (EVar "d2")) (EVar "s2")) (EVar "d1")))))
(DTypeSig false "underDir" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "underDir" ((PVar "dir") (PVar "stem") (PVar "xs")) (EMatch (EApp (EApp (EVar "dropListPrefix") (EVar "dir")) (EVar "xs")) (arm (PCon "Some" (PCons (PVar "next") PWild)) () (EBinOp "&&" (EBinOp "/=" (EVar "next") (ELit (LString ".."))) (EApp (EApp (EVar "startsWith") (EVar "stem")) (EVar "next")))) (arm PWild () (EVar "False"))))
(DTypeSig false "dropListPrefix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dropListPrefix" ((PList) (PVar "xs")) (EApp (EVar "Some") (EVar "xs")))
(DFunDef false "dropListPrefix" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "d") (EVar "x")) (EApp (EApp (EVar "dropListPrefix") (EVar "ds")) (EVar "xs")) (EVar "None")))
(DFunDef false "dropListPrefix" (PWild (PList)) (EVar "None"))
(DTypeSig false "pathJoin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Param"))))
(DFunDef false "pathJoin" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "ca") (EApp (EVar "prefixConcrete") (EApp (EVar "pathSpelling") (EVar "a")))) (DoLet false false (PVar "cb") (EApp (EVar "prefixConcrete") (EApp (EVar "pathSpelling") (EVar "b")))) (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "ca")) (EVar "cb")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "pathSpelling") (EVar "a")) (EApp (EVar "pathSpelling") (EVar "b"))) (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "a"))) (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "PPath") (EVar "None")) (EBlock (DoLet false false (PVar "joined") (EApp (EVar "pathSpelling") (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "k")) (EVar "ca")) (ELit (LString "*"))))) (DoLet false false (PVar "jk") (EApp (EVar "pathKey") (EVar "joined"))) (DoExpr (EIf (EBinOp "&&" (EApp (EApp (EVar "pathSub") (EApp (EVar "pathKey") (EVar "a"))) (EVar "jk")) (EApp (EApp (EVar "pathSub") (EApp (EVar "pathKey") (EVar "b"))) (EVar "jk"))) (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "joined"))) (EApp (EVar "PPath") (EVar "None"))))))))))
(DTypeSig false "isPathParam" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "isPathParam" ((PCon "PPath" PWild)) (EVar "True"))
(DFunDef false "isPathParam" (PWild) (EVar "False"))
(DTypeSig false "maximalPaths" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "maximalPaths" ((PVar "ps")) (EIf (EApp (EApp (EVar "allList") (EVar "isPathParam")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "pathSweep") (EApp (EApp (EVar "sortByKey") (EVar "pathEntryOrder")) (EApp (EApp (EVar "map") (EVar "pathEntry")) (EVar "ps")))) (EListLit)) (EVar "None")) (EListLit)) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EVar "keepMaximalPath") (EVar "p")) (EVar "acc")))) (EListLit)) (EVar "ps"))))
(DTypeSig false "keepMaximalPath" (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "keepMaximalPath" ((PVar "p") (PVar "acc")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "q")) (EApp (EApp (EVar "pathCovers") (EVar "q")) (EVar "p")))) (EVar "acc")) (EVar "acc") (EBinOp "::" (EVar "p") (EApp (EApp (EVar "filterList") (ELam ((PVar "q")) (EApp (EVar "not") (EApp (EApp (EVar "pathCovers") (EVar "p")) (EVar "q"))))) (EVar "acc")))))
(DTypeSig false "pathCovers" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "pathCovers" ((PVar "q") (PVar "p")) (EBinOp "&&" (EApp (EApp (EVar "dsubN") (EVar "p")) (EVar "q")) (EBinOp "||" (EBinOp "==" (EApp (EVar "paramSpelling") (EVar "p")) (EApp (EVar "paramSpelling") (EVar "q"))) (EApp (EVar "not") (EApp (EApp (EVar "dsubN") (EVar "q")) (EVar "p"))))))
(DTypeSig false "paramSpelling" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "paramSpelling" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EVar "s"))
(DFunDef false "paramSpelling" ((PCon "PPath" (PCon "Some" (PVar "s")))) (EApp (EVar "pathSpelling") (EVar "s")))
(DFunDef false "paramSpelling" (PWild) (ELit (LString "")))
(DData Private "PathEntry" () ((variant "PathEntry" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "PathKey") (TyCon "String") (TyCon "Param")))) ())
(DTypeSig false "pathEntry" (TyFun (TyCon "Param") (TyCon "PathEntry")))
(DFunDef false "pathEntry" ((PAs "p" (PCon "PPath" (PCon "Some" (PVar "s"))))) (EBlock (DoLet false false (PVar "k") (EApp (EVar "pathKey") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "PathEntry") (EApp (EVar "pathKeyText") (EVar "k"))) (EApp (EVar "keyCoversOthers") (EVar "k"))) (EVar "k")) (EApp (EVar "pathSpelling") (EVar "s"))) (EVar "p")))))
(DFunDef false "pathEntry" ((PVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "PathEntry") (ELit (LString ""))) (EVar "True")) (EVar "KAll")) (ELit (LString "*"))) (EVar "p")))
(DTypeSig false "pathKeyText" (TyFun (TyCon "PathKey") (TyCon "String")))
(DFunDef false "pathKeyText" ((PCon "KAll")) (ELit (LString "")))
(DFunDef false "pathKeyText" ((PCon "KExact" (PVar "abs") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rootTag") (EVar "abs")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "componentsText") (EVar "xs")))) (ELit (LString "/"))))
(DFunDef false "pathKeyText" ((PCon "KPattern" (PVar "abs") (PVar "dir") (PVar "stem"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rootTag") (EVar "abs")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "componentsText") (EVar "dir")))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "stem"))) (ELit (LString ""))))
(DFunDef false "pathKeyText" ((PCon "KPopped" (PVar "t"))) (EBinOp "++" (ELit (LString "x")) (EVar "t")))
(DTypeSig false "rootTag" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "rootTag" ((PVar "abs")) (EIf (EVar "abs") (ELit (LString "a")) (ELit (LString "r"))))
(DTypeSig false "componentsText" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "componentsText" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "/")) (EVar "_s")))) (EVar "xs"))))
(DTypeSig false "keyCoversOthers" (TyFun (TyCon "PathKey") (TyCon "Bool")))
(DFunDef false "keyCoversOthers" ((PCon "KAll")) (EVar "True"))
(DFunDef false "keyCoversOthers" ((PCon "KPattern" PWild PWild PWild)) (EVar "True"))
(DFunDef false "keyCoversOthers" (PWild) (EVar "False"))
(DTypeSig false "pathEntryOrder" (TyFun (TyCon "PathEntry") (TyFun (TyCon "PathEntry") (TyCon "Bool"))))
(DFunDef false "pathEntryOrder" ((PCon "PathEntry" (PVar "a") (PVar "ca") PWild (PVar "sa") PWild) (PCon "PathEntry" (PVar "b") (PVar "cb") PWild (PVar "sb") PWild)) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "a")) (EVar "b")) (arm (PCon "Lt") () (EVar "True")) (arm (PCon "Gt") () (EVar "False")) (arm (PCon "Eq") () (EIf (EBinOp "==" (EVar "ca") (EVar "cb")) (EBinOp "/=" (EApp (EApp (EVar "stringCompare") (EVar "sa")) (EVar "sb")) (EVar "Gt")) (EVar "ca")))))
(DTypeSig false "pathSweep" (TyFun (TyApp (TyCon "List") (TyCon "PathEntry")) (TyFun (TyApp (TyCon "List") (TyCon "PathEntry")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))))
(DFunDef false "pathSweep" ((PList) PWild PWild (PVar "kept")) (EVar "kept"))
(DFunDef false "pathSweep" ((PCons (PAs "e" (PCon "PathEntry" (PVar "t") (PVar "covers") PWild (PVar "sp") (PVar "p"))) (PVar "rest")) (PVar "open") (PVar "last") (PVar "kept")) (EBlock (DoLet false false (PVar "still") (EApp (EApp (EVar "dropOpenNotPrefix") (EVar "t")) (EVar "open"))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EVar "anyList") (EApp (EVar "entryCovers") (EVar "e"))) (EVar "still")) (EBinOp "==" (EVar "last") (EApp (EVar "Some") (ETuple (EVar "t") (EVar "sp"))))) (EApp (EApp (EApp (EApp (EVar "pathSweep") (EVar "rest")) (EVar "still")) (EVar "last")) (EVar "kept")) (EIf (EVar "covers") (EApp (EApp (EApp (EApp (EVar "pathSweep") (EVar "rest")) (EBinOp "::" (EVar "e") (EVar "still"))) (EVar "last")) (EBinOp "::" (EVar "p") (EVar "kept"))) (EApp (EApp (EApp (EApp (EVar "pathSweep") (EVar "rest")) (EVar "still")) (EApp (EVar "Some") (ETuple (EVar "t") (EVar "sp")))) (EBinOp "::" (EVar "p") (EVar "kept"))))))))
(DTypeSig false "dropOpenNotPrefix" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PathEntry")) (TyApp (TyCon "List") (TyCon "PathEntry")))))
(DFunDef false "dropOpenNotPrefix" (PWild (PList)) (EListLit))
(DFunDef false "dropOpenNotPrefix" ((PVar "t") (PCons (PAs "o" (PCon "PathEntry" (PVar "ot") PWild PWild PWild PWild)) (PVar "os"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "ot")) (EVar "t")) (EBinOp "::" (EVar "o") (EVar "os")) (EApp (EApp (EVar "dropOpenNotPrefix") (EVar "t")) (EVar "os"))))
(DTypeSig false "entryCovers" (TyFun (TyCon "PathEntry") (TyFun (TyCon "PathEntry") (TyCon "Bool"))))
(DFunDef false "entryCovers" ((PCon "PathEntry" PWild PWild (PVar "k") (PVar "sp") PWild) (PCon "PathEntry" PWild PWild (PVar "qk") (PVar "qsp") PWild)) (EBinOp "&&" (EApp (EApp (EVar "pathSub") (EVar "k")) (EVar "qk")) (EBinOp "||" (EBinOp "==" (EVar "sp") (EVar "qsp")) (EApp (EVar "not") (EApp (EApp (EVar "pathSub") (EVar "qk")) (EVar "k"))))))
(DTypeSig true "pathClimbs" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "pathClimbs" ((PCon "PPath" (PCon "Some" (PVar "s")))) (EMatch (EApp (EVar "pathKey") (EVar "s")) (arm (PCon "KExact" (PCon "False") (PCons (PLit (LString "..")) PWild)) () (EVar "True")) (arm (PCon "KPattern" (PCon "False") (PCons (PLit (LString "..")) PWild) PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DFunDef false "pathClimbs" (PWild) (EVar "False"))
(DTypeSig true "retagParam" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "retagParam" ((PCon "PPath" PWild) (PCon "PPrefix" (PCon "Some" (PVar "s")))) (EApp (EVar "canonParam") (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "retagParam" (PWild (PVar "p")) (EVar "p"))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "contains" false) (mem "allList" false) (mem "anyList" false) (mem "reverseL" false) (mem "lenKey" false) (mem "escStr" false) (mem "splitOnChar" false) (mem "splitLast" false))))
(DData Public "Param" () ((variant "PUnit" (ConPos)) (variant "PPrefix" (ConPos (TyApp (TyCon "Option") (TyCon "String")))) (variant "PPath" (ConPos (TyApp (TyCon "Option") (TyCon "String")))) (variant "PSet" (ConPos (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))) (variant "PProduct" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))) ())
(DTypeSig true "canonParam" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "canonParam" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "PPrefix") (EVar "None")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "canonParam" ((PCon "PPath" (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "PPath") (EVar "None")) (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "canonParam" ((PCon "PProduct" (PVar "ax"))) (EApp (EVar "productNorm") (EVar "ax")))
(DFunDef false "canonParam" ((PVar "p")) (EVar "p"))
(DTypeSig true "subTopOf" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "subTopOf" ((PCon "PPrefix" PWild)) (EApp (EVar "PPrefix") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PPath" PWild)) (EApp (EVar "PPath") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PSet" PWild)) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "subTopOf" ((PCon "PProduct" (PVar "ax"))) (EApp (EVar "PProduct") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "subTopOf") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax"))))
(DFunDef false "subTopOf" (PWild) (EVar "PUnit"))
(DTypeSig true "productPrimaryLift" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "String") (TyCon "Param"))))
(DFunDef false "productPrimaryLift" ((PList) PWild) (EApp (EVar "PProduct") (EListLit)))
(DFunDef false "productPrimaryLift" ((PCons (PTuple (PVar "name") (PVar "top")) (PVar "rest")) (PVar "s")) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "subTopOf") (EApp (EVar "snd") (EVar "a")))))) (EVar "rest"))) (DoExpr (EMatch (EVar "top") (arm (PCon "PPrefix" PWild) () (EApp (EVar "productNorm") (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))) (EVar "others")))) (arm (PCon "PSet" PWild) () (EApp (EVar "productNorm") (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "s"))))) (EVar "others")))) (arm PWild () (EApp (EVar "subTopOf") (EApp (EVar "PProduct") (EBinOp "::" (ETuple (EVar "name") (EVar "top")) (EVar "rest")))))))))
(DTypeSig true "productOver" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Param"))))
(DFunDef false "productOver" ((PVar "schema") (PVar "written")) (EApp (EVar "productNorm") (EApp (EApp (EMethodRef "map") (EApp (EVar "axisOver") (EVar "written"))) (EVar "schema"))))
(DTypeSig false "axisOver" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "axisOver" ((PVar "written") (PTuple (PVar "name") (PVar "top"))) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "written")) (arm (PCon "Some" (PCon "PUnit")) () (ETuple (EVar "name") (EApp (EVar "subTopOf") (EVar "top")))) (arm (PCon "Some" (PVar "v")) () (ETuple (EVar "name") (EVar "v"))) (arm (PCon "None") () (ETuple (EVar "name") (EApp (EVar "subTopOf") (EVar "top"))))))
(DTypeSig true "extendParam" (TyFun (TyCon "Param") (TyCon "Param")))
(DFunDef false "extendParam" ((PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (ELit (LString "*"))))))) (arm (PCon "PPath" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPath") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (ELit (LString "*")))))))) (arm (PCon "PProduct" (PCons (PTuple (PVar "name") (PVar "v")) (PVar "rest"))) () (EApp (EVar "productNorm") (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "extendParam") (EVar "v"))) (EVar "rest")))) (arm (PVar "q") () (EApp (EVar "subTopOf") (EVar "q")))))
(DTypeSig true "appendParam" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "appendParam" ((PVar "suffix") (PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (EVar "suffix"))))))) (arm (PCon "PPath" (PCon "Some" (PVar "s"))) () (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s"))) (EApp (EVar "canonParam") (EApp (EVar "PPath") (EApp (EVar "Some") (EBinOp "++" (EVar "s") (EVar "suffix"))))))) (arm (PCon "PProduct" (PCons (PTuple (PVar "name") (PVar "v")) (PVar "rest"))) () (EApp (EVar "productNorm") (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "appendParam") (EVar "suffix")) (EVar "v"))) (EVar "rest")))) (arm (PVar "q") () (EApp (EVar "subTopOf") (EVar "q")))))
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
(DFunDef false "djoinN" ((PCon "PPath" (PCon "None")) PWild) (EApp (EVar "PPath") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PPath" (PCon "None"))) (EApp (EVar "PPath") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PPath" (PCon "Some" (PVar "a"))) (PCon "PPath" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "pathJoin") (EVar "a")) (EVar "b")))
(DFunDef false "djoinN" ((PCon "PPath" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "pathJoin") (EVar "a")) (EVar "b")))
(DFunDef false "djoinN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPath" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "pathJoin") (EVar "a")) (EVar "b")))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "None")) PWild) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" (PWild (PCon "PSet" (PCon "None"))) (EApp (EVar "PSet") (EVar "None")))
(DFunDef false "djoinN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EBlock (DoLet false false (PVar "u") (EApp (EVar "sortUniqS") (EBinOp "++" (EVar "a") (EVar "b")))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "u")) (EVar "setCardCap")) (EApp (EVar "PSet") (EVar "None")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "u")))))))
(DFunDef false "djoinN" ((PAs "p" (PCon "PProduct" (PVar "ax"))) (PAs "q" (PCon "PProduct" (PVar "bx")))) (EIf (EBinOp "==" (EApp (EVar "domainKey") (EVar "p")) (EApp (EVar "domainKey") (EVar "q"))) (EApp (EVar "productNorm") (EApp (EApp (EMethodRef "map") (EApp (EVar "joinAxis") (EVar "bx"))) (EVar "ax"))) (EApp (EVar "subTopOf") (EVar "p"))))
(DFunDef false "djoinN" ((PVar "p") PWild) (EApp (EVar "subTopOf") (EVar "p")))
(DTypeSig true "dantichain" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "dantichain" ((PVar "ps")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EMethodRef "map") (EVar "canonParam")) (EVar "ps"))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EVar "anyList") (EVar "isSubTop")) (EVar "cs")) (EApp (EVar "not") (EApp (EVar "sameShape") (EVar "cs")))) (EListLit (EApp (EVar "subTopOf") (EApp (EVar "headParam") (EVar "cs")))) (EMatch (EVar "cs") (arm (PCons (PCon "PSet" PWild) PWild) () (EListLit (EApp (EVar "PSet") (EApp (EVar "Some") (EApp (EVar "sortUniqS") (EApp (EApp (EDictApp "flatMap") (EVar "setMembers")) (EVar "cs"))))))) (arm (PCons (PCon "PPrefix" PWild) PWild) () (EIf (EApp (EApp (EVar "anyList") (EVar "isPathParam")) (EVar "cs")) (EApp (EVar "sortParams") (EApp (EVar "maximalPaths") (EVar "cs"))) (EApp (EVar "sortParams") (EApp (EVar "maximalPrefixes") (EVar "cs"))))) (arm (PCons (PCon "PPath" PWild) PWild) () (EApp (EVar "sortParams") (EApp (EVar "maximalPaths") (EVar "cs")))) (arm (PCons (PCon "PProduct" PWild) PWild) () (EApp (EVar "sortParams") (EApp (EVar "canonProducts") (EVar "cs")))) (arm (PList) () (EListLit)) (arm PWild () (EApp (EVar "sortParams") (EApp (EVar "maximalOf") (EVar "cs")))))))))
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
(DFunDef false "canonProducts" ((PVar "ps")) (EBlock (DoLet false false (PVar "kept") (EApp (EVar "maximalOf") (EVar "ps"))) (DoExpr (EMatch (EApp (EVar "lastSetAxis") (EVar "kept")) (arm (PCon "None") () (EVar "kept")) (arm (PCon "Some" (PVar "axis")) () (EBlock (DoLet false false (PVar "groups") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EApp (EVar "addGroup") (EVar "axis")) (EVar "p")) (EVar "acc")))) (EListLit)) (EVar "kept"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "rebuildGroup") (EVar "axis")) (EVar "groups"))) (EVar "groups")))))))))
(DTypeSig false "sameShape" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Bool")))
(DFunDef false "sameShape" ((PList)) (EVar "True"))
(DFunDef false "sameShape" ((PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EVar "allList") (ELam ((PVar "q")) (EBinOp "==" (EApp (EVar "domainKey") (EVar "q")) (EApp (EVar "domainKey") (EVar "p"))))) (EVar "ps")))
(DTypeSig true "domainKey" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "domainKey" ((PCon "PUnit")) (ELit (LString "u")))
(DFunDef false "domainKey" ((PCon "PPrefix" PWild)) (ELit (LString "p")))
(DFunDef false "domainKey" ((PCon "PPath" PWild)) (ELit (LString "p")))
(DFunDef false "domainKey" ((PCon "PSet" PWild)) (ELit (LString "s")))
(DFunDef false "domainKey" ((PCon "PProduct" (PVar "ax"))) (EBinOp "++" (EBinOp "++" (ELit (LString "x(")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EBinOp "++" (EApp (EVar "lenKey") (EApp (EVar "fst") (EVar "a"))) (EApp (EVar "domainKey") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax")))) (ELit (LString ")"))))
(DData Private "PGroup" () ((variant "PGroup" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))) ())
(DTypeSig false "addGroup" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "PGroup")) (TyApp (TyCon "List") (TyCon "PGroup"))))))
(DFunDef false "addGroup" ((PVar "axis") (PVar "p") (PVar "gs")) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "otherAxes") (EVar "axis")) (EVar "p"))) (DoLet false false (PVar "key") (EApp (EVar "axesKey") (EVar "others"))) (DoLet false false (PVar "members") (EApp (EApp (EVar "axisMembers") (EVar "axis")) (EVar "p"))) (DoExpr (EMatch (EVar "gs") (arm (PList) () (EListLit (EApp (EApp (EApp (EApp (EVar "PGroup") (EVar "key")) (EVar "others")) (EVar "members")) (EApp (EVar "productAxes") (EVar "p"))))) (arm (PCons (PCon "PGroup" (PVar "k") (PVar "o") (PVar "ms") (PVar "t")) (PVar "rest")) () (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "PGroup") (EVar "k")) (EVar "o")) (EApp (EApp (EVar "unionMembers") (EVar "ms")) (EVar "members"))) (EVar "t")) (EVar "rest")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "PGroup") (EVar "k")) (EVar "o")) (EVar "ms")) (EVar "t")) (EApp (EApp (EApp (EVar "addGroup") (EVar "axis")) (EVar "p")) (EVar "rest")))))))))
(DTypeSig false "productAxes" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "productAxes" ((PCon "PProduct" (PVar "ax"))) (EVar "ax"))
(DFunDef false "productAxes" (PWild) (EListLit))
(DTypeSig false "withAxis" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))))
(DFunDef false "withAxis" ((PVar "name") (PVar "v") (PVar "axes")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EIf (EBinOp "==" (EApp (EVar "fst") (EVar "a")) (EVar "name")) (ETuple (EVar "name") (EVar "v")) (EVar "a")))) (EVar "axes")))
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
(DFunDef false "paramKey" ((PCon "PPath" (PCon "Some" (PVar "s")))) (EBinOp "++" (ELit (LString "f")) (EApp (EVar "lenKey") (EVar "s"))))
(DFunDef false "paramKey" ((PCon "PPath" (PCon "None"))) (ELit (LString "F")))
(DFunDef false "paramKey" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EBinOp "++" (ELit (LString "s")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "lenKey")) (EVar "xs")))))
(DFunDef false "paramKey" ((PCon "PSet" (PCon "None"))) (ELit (LString "S")))
(DFunDef false "paramKey" ((PCon "PProduct" (PVar "ax"))) (EBinOp "++" (EBinOp "++" (ELit (LString "x(")) (EApp (EVar "axesKey") (EVar "ax"))) (ELit (LString ")"))))
(DFunDef false "paramKey" ((PCon "PUnit")) (ELit (LString "u")))
(DTypeSig false "rebuildGroup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PGroup")) (TyFun (TyCon "PGroup") (TyApp (TyCon "List") (TyCon "Param"))))))
(DFunDef false "rebuildGroup" ((PVar "axis") (PVar "gs") (PCon "PGroup" (PVar "key") (PVar "others") (PVar "members") (PVar "template"))) (EBlock (DoLet false false (PVar "coverers") (EApp (EApp (EVar "filterList") (ELam ((PVar "g")) (EMatch (EVar "g") (arm (PCon "PGroup" (PVar "k") (PVar "o") PWild PWild) () (EBinOp "&&" (EBinOp "/=" (EVar "k") (EVar "key")) (EApp (EApp (EVar "dsubN") (EApp (EVar "productNorm") (EVar "others"))) (EApp (EVar "productNorm") (EVar "o")))))))) (EVar "gs"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "g")) (EBinOp "==" (EApp (EVar "groupMembersOf") (EVar "g")) (EVar "None")))) (EVar "coverers")) (EListLit) (EMatch (EVar "members") (arm (PCon "None") () (EListLit (EApp (EVar "productNorm") (EApp (EApp (EApp (EVar "withAxis") (EVar "axis")) (EApp (EVar "PSet") (EVar "None"))) (EVar "template"))))) (arm (PCon "Some" (PVar "xs")) () (EBlock (DoLet false false (PVar "taken") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "g")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EVar "groupMembersOf") (EVar "g"))))) (EVar "coverers"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "x")) (EVar "taken"))))) (EApp (EVar "sortUniqS") (EVar "xs"))) (arm (PList) () (EListLit)) (arm (PVar "left") () (EListLit (EApp (EVar "productNorm") (EApp (EApp (EApp (EVar "withAxis") (EVar "axis")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "left")))) (EVar "template"))))))))))))))
(DTypeSig false "groupMembersOf" (TyFun (TyCon "PGroup") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "groupMembersOf" ((PCon "PGroup" PWild PWild (PVar "ms") PWild)) (EVar "ms"))
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
(DTypeSig false "joinAxis" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyCon "Param")))))
(DFunDef false "joinAxis" ((PVar "bx") (PTuple (PVar "name") (PVar "pa"))) (EMatch (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "bx")) (arm (PCon "Some" (PVar "pb")) () (ETuple (EVar "name") (EApp (EApp (EVar "djoinN") (EVar "pa")) (EVar "pb")))) (arm (PCon "None") () (ETuple (EVar "name") (EApp (EVar "subTopOf") (EVar "pa"))))))
(DTypeSig true "productNorm" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "Param")))
(DFunDef false "productNorm" ((PVar "axes")) (EApp (EVar "PProduct") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "canonParam") (EApp (EVar "snd") (EVar "a")))))) (EVar "axes"))))
(DTypeSig true "isSubTop" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "isSubTop" ((PCon "PPrefix" (PCon "None"))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PPath" (PCon "None"))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "isSubTop" ((PCon "PProduct" (PVar "ax"))) (EApp (EApp (EVar "allList") (ELam ((PVar "a")) (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "a"))))) (EVar "ax")))
(DFunDef false "isSubTop" ((PCon "PUnit")) (EVar "True"))
(DFunDef false "isSubTop" (PWild) (EVar "False"))
(DTypeSig true "setCardCap" (TyCon "Int"))
(DFunDef false "setCardCap" () (ELit (LInt 16)))
(DTypeSig true "commonPrefixLen" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "commonPrefixLen" ((PVar "a") (PVar "b") (PVar "i")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "a"))) (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "b")))) (EVar "i") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "a")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "b"))) (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i"))))
(DTypeSig true "drender" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "drender" ((PVar "p")) (EApp (EVar "drenderN") (EApp (EVar "canonParam") (EVar "p"))))
(DTypeSig true "drenderN" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "drenderN" ((PCon "PUnit")) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PPrefix" (PCon "None"))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EBinOp "++" (ELit (LString " ")) (EApp (EVar "quoteStr") (EVar "s"))))
(DFunDef false "drenderN" ((PCon "PPath" (PCon "None"))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PPath" (PCon "Some" (PVar "s")))) (EBinOp "++" (ELit (LString " ")) (EApp (EVar "quoteStr") (EApp (EVar "pathSpelling") (EVar "s")))))
(DFunDef false "drenderN" ((PCon "PSet" (PCon "None"))) (ELit (LString "")))
(DFunDef false "drenderN" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EBinOp "++" (EBinOp "++" (ELit (LString " {")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoteStr")) (EVar "xs")))) (ELit (LString "}"))))
(DFunDef false "drenderN" ((PCon "PProduct" (PVar "ax"))) (EMatch (EApp (EVar "renderProductLit") (EVar "ax")) (arm (PLit (LString "")) () (ELit (LString ""))) (arm (PVar "r") () (EBinOp "++" (ELit (LString " ")) (EVar "r")))))
(DTypeSig true "quoteStr" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteStr" ((PVar "s")) (EApp (EVar "escStr") (EVar "s")))
(DTypeSig true "renderProductLit" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "renderProductLit" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "renderAxis")) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax")))))
(DTypeSig true "renderAxis" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "renderAxis" ((PTuple (PVar "name") (PVar "p"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EApp (EVar "renderAxisVal") (EVar "p")))) (ELit (LString ""))))
(DTypeSig true "renderAxisVal" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "renderAxisVal" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EApp (EVar "quoteStr") (EVar "s")))
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
(DFunDef false "dsubN" (PWild (PCon "PPath" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PPath" (PCon "Some" (PVar "a"))) (PCon "PPath" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "pathSub") (EApp (EVar "pathKey") (EVar "a"))) (EApp (EVar "pathKey") (EVar "b"))))
(DFunDef false "dsubN" ((PCon "PPrefix" (PCon "Some" (PVar "a"))) (PCon "PPath" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "pathSub") (EApp (EVar "pathKey") (EVar "a"))) (EApp (EVar "pathKey") (EVar "b"))))
(DFunDef false "dsubN" ((PCon "PPath" (PCon "Some" (PVar "a"))) (PCon "PPrefix" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "dsubN") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "a")))) (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "b")))))
(DFunDef false "dsubN" (PWild (PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "Some" (PVar "a"))) (PCon "PSet" (PCon "Some" (PVar "b")))) (EApp (EApp (EVar "subsetStr") (EVar "a")) (EVar "b")))
(DFunDef false "dsubN" ((PCon "PSet" (PCon "None")) (PCon "PSet" (PCon "Some" PWild))) (EVar "False"))
(DFunDef false "dsubN" (PWild (PCon "PProduct" (PList))) (EVar "True"))
(DFunDef false "dsubN" ((PAs "p" (PCon "PProduct" (PVar "ax"))) (PAs "q" (PCon "PProduct" (PVar "bx")))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "domainKey") (EVar "p")) (EApp (EVar "domainKey") (EVar "q"))) (EApp (EApp (EVar "allList") (EApp (EVar "axisSub") (EVar "ax"))) (EVar "bx"))))
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
(DData Private "PathKey" () ((variant "KAll" (ConPos)) (variant "KExact" (ConPos (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))) (variant "KPattern" (ConPos (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))) (variant "KPopped" (ConPos (TyCon "String")))) ())
(DTypeSig true "pathSpelling" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "pathSpelling" ((PVar "s")) (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "prefixConcrete") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LString ""))) (EVar "s") (EBinOp "++" (EApp (EVar "appendForm") (EVar "c")) (ELit (LString "*")))))) (EApp (EVar "appendForm") (EVar "s"))))
(DTypeSig false "appendForm" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "appendForm" ((PVar "c")) (EMatch (EApp (EVar "splitLast") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "c"))) (arm (PCon "Some" (PTuple (PList) (PVar "last"))) () (EVar "last")) (arm (PCon "Some" (PTuple (PVar "dir") (PVar "last"))) () (EBlock (DoLet false false (PVar "abs") (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "c"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "dirSpelling") (EMethodRef "abs")) (EApp (EApp (EVar "lexicalPath") (EMethodRef "abs")) (EVar "dir"))) (EVar "last")) (EVar "last"))))) (arm (PCon "None") () (EVar "c"))))
(DTypeSig false "dirSpelling" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "dirSpelling" ((PCon "True") (PList) PWild) (ELit (LString "/")))
(DFunDef false "dirSpelling" ((PCon "True") (PVar "d") PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "/")) (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "d"))) (ELit (LString "/"))))
(DFunDef false "dirSpelling" ((PCon "False") (PList) (PVar "last")) (EIf (EBinOp "==" (EVar "last") (ELit (LString ""))) (ELit (LString "./")) (ELit (LString ""))))
(DFunDef false "dirSpelling" ((PCon "False") (PVar "d") PWild) (EBinOp "++" (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "d")) (ELit (LString "/"))))
(DTypeSig false "pathKey" (TyFun (TyCon "String") (TyCon "PathKey")))
(DFunDef false "pathKey" ((PVar "s")) (EIf (EApp (EVar "isPrefixPattern") (EVar "s")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "prefixConcrete") (EVar "s"))) (DoLet false false (PVar "abs") (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "c"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LString ""))) (EVar "KAll") (EMatch (EApp (EVar "splitLast") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "c"))) (arm (PCon "Some" (PTuple (PVar "dir") (PVar "stem"))) () (EBlock (DoLet false false (PVar "d") (EApp (EApp (EVar "lexicalPath") (EMethodRef "abs")) (EVar "dir"))) (DoExpr (EIf (EApp (EApp (EVar "popsNamed") (EVar "False")) (EVar "d")) (EApp (EVar "KPopped") (EBinOp "++" (ELit (LString "p")) (EApp (EVar "pathSpelling") (EVar "s")))) (EApp (EApp (EApp (EVar "KPattern") (EMethodRef "abs")) (EVar "d")) (EVar "stem")))))) (arm (PCon "None") () (EVar "KAll")))))) (EBlock (DoLet false false (PVar "abs") (EApp (EApp (EVar "startsWith") (ELit (LString "/"))) (EVar "s"))) (DoLet false false (PVar "xs") (EApp (EApp (EVar "lexicalPath") (EMethodRef "abs")) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "s")))) (DoExpr (EIf (EApp (EApp (EVar "popsNamed") (EVar "False")) (EVar "xs")) (EApp (EVar "KPopped") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "e")) (EApp (EMethodRef "display") (EApp (EVar "rootSlash") (EMethodRef "abs")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "xs")))) (ELit (LString "")))) (EApp (EApp (EVar "KExact") (EMethodRef "abs")) (EVar "xs")))))))
(DTypeSig false "rootSlash" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "rootSlash" ((PVar "abs")) (EIf (EMethodRef "abs") (ELit (LString "/")) (ELit (LString ""))))
(DTypeSig false "lexicalPath" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lexicalPath" ((PVar "abs") (PVar "parts")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "lexicalStep") (EMethodRef "abs"))) (EListLit)) (EVar "parts"))))
(DTypeSig false "lexicalStep" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lexicalStep" ((PVar "abs") (PVar "acc") (PVar "c")) (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LString ""))) (EBinOp "==" (EVar "c") (ELit (LString ".")))) (EVar "acc") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LString ".."))) (EMethodRef "abs")) (EApp (EVar "isEmptyList") (EVar "acc"))) (EVar "acc") (EIf (EVar "otherwise") (EBinOp "::" (EVar "c") (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isEmptyList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isEmptyList" ((PList)) (EVar "True"))
(DFunDef false "isEmptyList" (PWild) (EVar "False"))
(DTypeSig false "popsNamed" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "popsNamed" (PWild (PList)) (EVar "False"))
(DFunDef false "popsNamed" ((PVar "named") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EVar "c") (ELit (LString ".."))) (EBinOp "||" (EVar "named") (EApp (EApp (EVar "popsNamed") (EVar "named")) (EVar "cs"))) (EApp (EApp (EVar "popsNamed") (EVar "True")) (EVar "cs"))))
(DTypeSig false "pathSub" (TyFun (TyCon "PathKey") (TyFun (TyCon "PathKey") (TyCon "Bool"))))
(DFunDef false "pathSub" (PWild (PCon "KAll")) (EVar "True"))
(DFunDef false "pathSub" ((PCon "KAll") PWild) (EVar "False"))
(DFunDef false "pathSub" ((PCon "KPopped" (PVar "a")) (PCon "KPopped" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "pathSub" ((PCon "KPopped" PWild) PWild) (EVar "False"))
(DFunDef false "pathSub" (PWild (PCon "KPopped" PWild)) (EVar "False"))
(DFunDef false "pathSub" ((PCon "KExact" (PVar "a") (PVar "xs")) (PCon "KExact" (PVar "b") (PVar "ys"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "==" (EVar "xs") (EVar "ys"))))
(DFunDef false "pathSub" ((PCon "KExact" (PVar "a") (PVar "xs")) (PCon "KPattern" (PVar "b") (PVar "dir") (PVar "stem"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "xs") (EVar "dir")) (EBinOp "==" (EVar "stem") (ELit (LString "")))) (EApp (EApp (EApp (EVar "underDir") (EVar "dir")) (EVar "stem")) (EVar "xs")))))
(DFunDef false "pathSub" ((PCon "KPattern" PWild PWild PWild) (PCon "KExact" PWild PWild)) (EVar "False"))
(DFunDef false "pathSub" ((PCon "KPattern" (PVar "a") (PVar "d1") (PVar "s1")) (PCon "KPattern" (PVar "b") (PVar "d2") (PVar "s2"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "d1") (EVar "d2")) (EApp (EApp (EVar "startsWith") (EVar "s2")) (EVar "s1"))) (EApp (EApp (EApp (EVar "underDir") (EVar "d2")) (EVar "s2")) (EVar "d1")))))
(DTypeSig false "underDir" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "underDir" ((PVar "dir") (PVar "stem") (PVar "xs")) (EMatch (EApp (EApp (EVar "dropListPrefix") (EVar "dir")) (EVar "xs")) (arm (PCon "Some" (PCons (PVar "next") PWild)) () (EBinOp "&&" (EBinOp "/=" (EVar "next") (ELit (LString ".."))) (EApp (EApp (EVar "startsWith") (EVar "stem")) (EVar "next")))) (arm PWild () (EVar "False"))))
(DTypeSig false "dropListPrefix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dropListPrefix" ((PList) (PVar "xs")) (EApp (EVar "Some") (EVar "xs")))
(DFunDef false "dropListPrefix" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "d") (EVar "x")) (EApp (EApp (EVar "dropListPrefix") (EVar "ds")) (EVar "xs")) (EVar "None")))
(DFunDef false "dropListPrefix" (PWild (PList)) (EVar "None"))
(DTypeSig false "pathJoin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Param"))))
(DFunDef false "pathJoin" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "ca") (EApp (EVar "prefixConcrete") (EApp (EVar "pathSpelling") (EVar "a")))) (DoLet false false (PVar "cb") (EApp (EVar "prefixConcrete") (EApp (EVar "pathSpelling") (EVar "b")))) (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "commonPrefixLen") (EVar "ca")) (EVar "cb")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "pathSpelling") (EVar "a")) (EApp (EVar "pathSpelling") (EVar "b"))) (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "a"))) (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "PPath") (EVar "None")) (EBlock (DoLet false false (PVar "joined") (EApp (EVar "pathSpelling") (EBinOp "++" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "k")) (EVar "ca")) (ELit (LString "*"))))) (DoLet false false (PVar "jk") (EApp (EVar "pathKey") (EVar "joined"))) (DoExpr (EIf (EBinOp "&&" (EApp (EApp (EVar "pathSub") (EApp (EVar "pathKey") (EVar "a"))) (EVar "jk")) (EApp (EApp (EVar "pathSub") (EApp (EVar "pathKey") (EVar "b"))) (EVar "jk"))) (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "joined"))) (EApp (EVar "PPath") (EVar "None"))))))))))
(DTypeSig false "isPathParam" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "isPathParam" ((PCon "PPath" PWild)) (EVar "True"))
(DFunDef false "isPathParam" (PWild) (EVar "False"))
(DTypeSig false "maximalPaths" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "maximalPaths" ((PVar "ps")) (EIf (EApp (EApp (EVar "allList") (EVar "isPathParam")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "pathSweep") (EApp (EApp (EVar "sortByKey") (EVar "pathEntryOrder")) (EApp (EApp (EMethodRef "map") (EVar "pathEntry")) (EVar "ps")))) (EListLit)) (EVar "None")) (EListLit)) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EVar "keepMaximalPath") (EVar "p")) (EVar "acc")))) (EListLit)) (EVar "ps"))))
(DTypeSig false "keepMaximalPath" (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "keepMaximalPath" ((PVar "p") (PVar "acc")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "q")) (EApp (EApp (EVar "pathCovers") (EVar "q")) (EVar "p")))) (EVar "acc")) (EVar "acc") (EBinOp "::" (EVar "p") (EApp (EApp (EVar "filterList") (ELam ((PVar "q")) (EApp (EVar "not") (EApp (EApp (EVar "pathCovers") (EVar "p")) (EVar "q"))))) (EVar "acc")))))
(DTypeSig false "pathCovers" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Bool"))))
(DFunDef false "pathCovers" ((PVar "q") (PVar "p")) (EBinOp "&&" (EApp (EApp (EVar "dsubN") (EVar "p")) (EVar "q")) (EBinOp "||" (EBinOp "==" (EApp (EVar "paramSpelling") (EVar "p")) (EApp (EVar "paramSpelling") (EVar "q"))) (EApp (EVar "not") (EApp (EApp (EVar "dsubN") (EVar "q")) (EVar "p"))))))
(DTypeSig false "paramSpelling" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "paramSpelling" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EVar "s"))
(DFunDef false "paramSpelling" ((PCon "PPath" (PCon "Some" (PVar "s")))) (EApp (EVar "pathSpelling") (EVar "s")))
(DFunDef false "paramSpelling" (PWild) (ELit (LString "")))
(DData Private "PathEntry" () ((variant "PathEntry" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "PathKey") (TyCon "String") (TyCon "Param")))) ())
(DTypeSig false "pathEntry" (TyFun (TyCon "Param") (TyCon "PathEntry")))
(DFunDef false "pathEntry" ((PAs "p" (PCon "PPath" (PCon "Some" (PVar "s"))))) (EBlock (DoLet false false (PVar "k") (EApp (EVar "pathKey") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "PathEntry") (EApp (EVar "pathKeyText") (EVar "k"))) (EApp (EVar "keyCoversOthers") (EVar "k"))) (EVar "k")) (EApp (EVar "pathSpelling") (EVar "s"))) (EVar "p")))))
(DFunDef false "pathEntry" ((PVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "PathEntry") (ELit (LString ""))) (EVar "True")) (EVar "KAll")) (ELit (LString "*"))) (EVar "p")))
(DTypeSig false "pathKeyText" (TyFun (TyCon "PathKey") (TyCon "String")))
(DFunDef false "pathKeyText" ((PCon "KAll")) (ELit (LString "")))
(DFunDef false "pathKeyText" ((PCon "KExact" (PVar "abs") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rootTag") (EMethodRef "abs")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "componentsText") (EVar "xs")))) (ELit (LString "/"))))
(DFunDef false "pathKeyText" ((PCon "KPattern" (PVar "abs") (PVar "dir") (PVar "stem"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rootTag") (EMethodRef "abs")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "componentsText") (EVar "dir")))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "stem"))) (ELit (LString ""))))
(DFunDef false "pathKeyText" ((PCon "KPopped" (PVar "t"))) (EBinOp "++" (ELit (LString "x")) (EVar "t")))
(DTypeSig false "rootTag" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "rootTag" ((PVar "abs")) (EIf (EMethodRef "abs") (ELit (LString "a")) (ELit (LString "r"))))
(DTypeSig false "componentsText" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "componentsText" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "/")) (EVar "_s")))) (EVar "xs"))))
(DTypeSig false "keyCoversOthers" (TyFun (TyCon "PathKey") (TyCon "Bool")))
(DFunDef false "keyCoversOthers" ((PCon "KAll")) (EVar "True"))
(DFunDef false "keyCoversOthers" ((PCon "KPattern" PWild PWild PWild)) (EVar "True"))
(DFunDef false "keyCoversOthers" (PWild) (EVar "False"))
(DTypeSig false "pathEntryOrder" (TyFun (TyCon "PathEntry") (TyFun (TyCon "PathEntry") (TyCon "Bool"))))
(DFunDef false "pathEntryOrder" ((PCon "PathEntry" (PVar "a") (PVar "ca") PWild (PVar "sa") PWild) (PCon "PathEntry" (PVar "b") (PVar "cb") PWild (PVar "sb") PWild)) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "a")) (EVar "b")) (arm (PCon "Lt") () (EVar "True")) (arm (PCon "Gt") () (EVar "False")) (arm (PCon "Eq") () (EIf (EBinOp "==" (EVar "ca") (EVar "cb")) (EBinOp "/=" (EApp (EApp (EVar "stringCompare") (EVar "sa")) (EVar "sb")) (EVar "Gt")) (EVar "ca")))))
(DTypeSig false "pathSweep" (TyFun (TyApp (TyCon "List") (TyCon "PathEntry")) (TyFun (TyApp (TyCon "List") (TyCon "PathEntry")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Param")))))))
(DFunDef false "pathSweep" ((PList) PWild PWild (PVar "kept")) (EVar "kept"))
(DFunDef false "pathSweep" ((PCons (PAs "e" (PCon "PathEntry" (PVar "t") (PVar "covers") PWild (PVar "sp") (PVar "p"))) (PVar "rest")) (PVar "open") (PVar "last") (PVar "kept")) (EBlock (DoLet false false (PVar "still") (EApp (EApp (EVar "dropOpenNotPrefix") (EVar "t")) (EVar "open"))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EVar "anyList") (EApp (EVar "entryCovers") (EVar "e"))) (EVar "still")) (EBinOp "==" (EVar "last") (EApp (EVar "Some") (ETuple (EVar "t") (EVar "sp"))))) (EApp (EApp (EApp (EApp (EVar "pathSweep") (EVar "rest")) (EVar "still")) (EVar "last")) (EVar "kept")) (EIf (EVar "covers") (EApp (EApp (EApp (EApp (EVar "pathSweep") (EVar "rest")) (EBinOp "::" (EVar "e") (EVar "still"))) (EVar "last")) (EBinOp "::" (EVar "p") (EVar "kept"))) (EApp (EApp (EApp (EApp (EVar "pathSweep") (EVar "rest")) (EVar "still")) (EApp (EVar "Some") (ETuple (EVar "t") (EVar "sp")))) (EBinOp "::" (EVar "p") (EVar "kept"))))))))
(DTypeSig false "dropOpenNotPrefix" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PathEntry")) (TyApp (TyCon "List") (TyCon "PathEntry")))))
(DFunDef false "dropOpenNotPrefix" (PWild (PList)) (EListLit))
(DFunDef false "dropOpenNotPrefix" ((PVar "t") (PCons (PAs "o" (PCon "PathEntry" (PVar "ot") PWild PWild PWild PWild)) (PVar "os"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "ot")) (EVar "t")) (EBinOp "::" (EVar "o") (EVar "os")) (EApp (EApp (EVar "dropOpenNotPrefix") (EVar "t")) (EVar "os"))))
(DTypeSig false "entryCovers" (TyFun (TyCon "PathEntry") (TyFun (TyCon "PathEntry") (TyCon "Bool"))))
(DFunDef false "entryCovers" ((PCon "PathEntry" PWild PWild (PVar "k") (PVar "sp") PWild) (PCon "PathEntry" PWild PWild (PVar "qk") (PVar "qsp") PWild)) (EBinOp "&&" (EApp (EApp (EVar "pathSub") (EVar "k")) (EVar "qk")) (EBinOp "||" (EBinOp "==" (EVar "sp") (EVar "qsp")) (EApp (EVar "not") (EApp (EApp (EVar "pathSub") (EVar "qk")) (EVar "k"))))))
(DTypeSig true "pathClimbs" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "pathClimbs" ((PCon "PPath" (PCon "Some" (PVar "s")))) (EMatch (EApp (EVar "pathKey") (EVar "s")) (arm (PCon "KExact" (PCon "False") (PCons (PLit (LString "..")) PWild)) () (EVar "True")) (arm (PCon "KPattern" (PCon "False") (PCons (PLit (LString "..")) PWild) PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DFunDef false "pathClimbs" (PWild) (EVar "False"))
(DTypeSig true "retagParam" (TyFun (TyCon "Param") (TyFun (TyCon "Param") (TyCon "Param"))))
(DFunDef false "retagParam" ((PCon "PPath" PWild) (PCon "PPrefix" (PCon "Some" (PVar "s")))) (EApp (EVar "canonParam") (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s")))))
(DFunDef false "retagParam" (PWild (PVar "p")) (EVar "p"))
