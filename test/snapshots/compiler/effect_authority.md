# META
source_lines=523
stages=DESUGAR,MARK
# SOURCE
-- Authority terms: the parameter of an effect atom as inference sees it. A
-- term is a concrete element of the label's domain, a scoped authority
-- variable, or a join of terms. A join's constants are kept as the domain's
-- antichain (`dantichain`), so a join of two Prefix patterns is the set of
-- both, never their common prefix; its variables stay symbolic.
-- Coverage is decided only where it is provable now: a variable covers itself
-- and is covered by top, a join is covered when every operand is and covers
-- when any operand does, and a Product tuple is compared axis by axis.
-- Anything else is not proven, never assumed.

import types.effect_domain.{
  Param(..), dsub, canonParam, drender, isSubTop, subTopOf, extendParam,
  appendParam, dantichain, dsubAny, djoinN, setCardCap, productNorm,
  renderAxisVal, lookupAxis, domainKey
}
import support.util.{
  joinWith, reverseL, listLen, anyList, allList, dedupBy, filterList
}
import string.{trimLeft}
import map as M
import map.{Map(..)}

-- `AProduct` is one element of a Product domain whose axes are terms rather
-- than values: every axis of the label's schema, in declaration order, each a
-- term of that axis's own domain. A signature writes one when an argument
-- names an axis (`<Http Host=host Method=method>`); once no axis holds a
-- variable it is an ordinary Product constant (`authNorm`).
public export data Authority =
  | AConst Param
  | AVar (Ref Authvar)
  | AJoin (List Authority)
  | AProduct (List (String, Authority))

-- id, inference level, the domain's top, whether the variable ranges over
-- the domain's patterns only (a binder written `@L*` or `Authority L*`), and
-- the source binder's name when the variable came from a written signature.
-- Identity belongs to the cell and survives linking, as an effect variable's
-- does, and so does the domain: a linked variable still has its label's
-- declared schema, never the axes of the constant it was linked to.
public export data Authvar =
  | AUnbound Int Int Param Bool (Option String)
  | ALink Int Param Authority

export
authvarId : Ref Authvar -> Int
authvarId cell = match !cell
  AUnbound id _ _ _ _ => id
  ALink id _ _ => id

export
authvarLevel : Ref Authvar -> Int
authvarLevel cell = match !cell
  AUnbound _ level _ _ _ => level
  ALink _ _ a => authLevelOf a

authLevelOf : Authority -> Int
authLevelOf (AVar cell) = authvarLevel cell
authLevelOf (AJoin ms) = fold (acc m => max acc (authLevelOf m)) 0 ms
authLevelOf (AProduct axes) =
  fold (acc a => max acc (authLevelOf (snd a))) 0 axes
authLevelOf _ = 0

export
authvarDomain : Ref Authvar -> Param
authvarDomain cell = match !cell
  AUnbound _ _ top _ _ => top
  ALink _ top _ => top

export
authvarName : Ref Authvar -> Option String
authvarName cell = match !cell
  AUnbound _ _ _ _ name => name
  ALink _ _ _ => None

-- Whether an unbound variable ranges over its domain's patterns only. A
-- linked cell is no longer a variable; its target answers for it.
export
authvarIsPattern : Ref Authvar -> Bool
authvarIsPattern cell = match !cell
  AUnbound _ _ _ pat _ => pat
  ALink _ _ target => authIsPattern target

-- Narrow a flexible variable to its domain's patterns: it now stands for
-- what a pattern-ranging variable it was equated with stands for. Only a
-- flexible variable may be narrowed, since a rigid one is a caller's choice.
export
markAuthvarPattern : Ref Authvar -> Unit
markAuthvarPattern cell = match !cell
  AUnbound id level top _ name => cell := AUnbound id level top True name
  ALink _ _ _ => ()

-- Every solution goes through here, so a pattern-ranging variable never
-- links outside its range: the term is closed to the least pattern above it
-- (`authPatternClose`), which leaves a term already in the range unchanged.
-- A caller that must refuse a term outside the range (an index equality with
-- an exact element) decides that before linking.
export
linkAuthvar : Ref Authvar -> Authority -> Unit
linkAuthvar cell a =
  let target = if authvarIsPattern cell then authPatternClose a else a
  cell := ALink (authvarId cell) (authvarDomain cell) target

-- The least term of the pattern range above [a] (the closure π of
-- EFFECTS-SEMANTICS §4.1): each constant extended to the pattern it begins,
-- a Product on its primary axis, a pattern-ranging variable kept, and any
-- other variable the domain's top, since what it stands for may be an exact
-- element.
export
authPatternClose : Authority -> Authority
authPatternClose a = mapConstants extendParam a

-- Whether [a] lies in the pattern range: every constant a pattern (a fixed
-- point of `extendParam`, on a Product's primary axis) and every variable
-- pattern-ranging.
export
authIsPattern : Authority -> Bool
authIsPattern a = match authNorm a
  AConst p => isPatternParam p
  AVar cell => authvarIsPattern cell
  AJoin ms => allList authIsPattern ms
  AProduct ((_, t) :: _) => authIsPattern t
  AProduct [] => True

export
isPatternParam : Param -> Bool
isPatternParam p = dsub (extendParam p) p

export
authTop : Param -> Authority
authTop top = AConst (subTopOf top)

-- The authority of a value once a suffix is appended: each constant extends
-- through its domain, by the suffix when it is known (`authAppend`) and to
-- the pattern it begins when it is not (`authExtend`). A variable extends to
-- its domain's top: what it stands for is not known here, and an exact
-- element has no extension inside itself, so no narrower bound is sound. A
-- pattern-ranging variable is the exception: whatever it stands for is a
-- pattern, which admits every extension of a value within it, so it extends
-- to itself.
export
authExtend : Authority -> Authority
authExtend a = mapConstants extendParam a

export
authAppend : String -> Authority -> Authority
authAppend suffix a = mapConstants (appendParam suffix) a

-- A Product tuple extends on its primary axis only, as a constant does
-- (`extendParam`).
mapConstants : (Param -> Param) -> Authority -> Authority
mapConstants f a = match authNorm a
  AConst p => AConst (f p)
  AJoin ms => authJoinAll (map (mapConstants f) ms)
  AProduct ((name, t) :: rest) =>
    authNorm (AProduct ((name, mapConstants f t) :: rest))
  AVar cell =>
    if authvarIsPattern cell then AVar cell else authTop (authvarDomain cell)
  v => v

-- The domain's top for a term: from a constant's shape, or a variable's
-- declared domain. An empty join (the empty authority, a variable's least
-- solution when nothing bounds it below) has no domain of its own.
export
authDomainTop : Authority -> Param
authDomainTop (AConst p) = subTopOf p
authDomainTop (AVar cell) = authvarDomain cell
authDomainTop (AProduct axes) =
  PProduct (map (a => (fst a, authDomainTop (snd a))) axes)
-- A join's domain is a variable's when it has one, else its first member's.
authDomainTop (AJoin ms) = match filterVars ms
  v :: _ => authDomainTop v
  [] => match ms
    m :: _ => authDomainTop m
    [] => PUnit

filterVars : List Authority -> List Authority
filterVars [] = []
filterVars ((AVar c) :: ms) = AVar c :: filterVars ms
filterVars (_ :: ms) = filterVars ms

-- Canonical form: links followed, joins flattened, constants kept as the
-- domain's antichain ahead of the Product tuples and then the variables,
-- tuples and variables deduplicated, a top constant absorbing everything, and
-- a one-operand join collapsed.
export
authNorm : Authority -> Authority
authNorm a =
  let (consts, tuples, vars) = collect [a] (Parts [] [] Tip)
  match dantichain consts
    [c] => if isSubTop c then AConst c else assemble [c] tuples vars
    cs => assemble cs tuples vars

-- A term's operands, gathered: constants, Product tuples that still hold a
-- variable, and variables by identity.
data Parts = Parts (List Param) (List Authority) (Map Int (Ref Authvar))

collect : List Authority ->
  Parts ->
  (List Param, List Authority, Map Int (Ref Authvar))
collect [] (Parts consts tuples vars) = (consts, reverseL tuples, vars)
collect ((AConst p) :: rest) (Parts consts tuples vars) =
  collect rest (Parts (p :: consts) tuples vars)
collect ((AVar cell) :: rest) (Parts consts tuples vars) = match !cell
  ALink _ _ target => collect (target :: rest) (Parts consts tuples vars)
  AUnbound id _ _ _ _ => collect rest (Parts consts tuples (M.set id cell vars))
collect ((AJoin ms) :: rest) parts = collect (ms ++ rest) parts
collect ((AProduct axes) :: rest) (Parts consts tuples vars) =
  match productTerm axes
    AProduct normed =>
      collect rest (Parts consts (AProduct normed :: tuples) vars)
    other => collect (other :: rest) (Parts consts tuples vars)

-- A tuple with every axis normalised. An empty axis makes the tuple empty;
-- once no axis holds a variable the tuple is the join of the constant tuples
-- its axes span, which is exact, since a product of sets is the set of its
-- tuples.
productTerm : List (String, Authority) -> Authority
productTerm axes =
  let normed = map (a => (fst a, authNorm (snd a))) axes
  if anyList (a => isEmptyAuth (snd a)) normed then
    AJoin []
  else match axisConstants normed
    Some choices => AJoin (map (ax => AConst (productNorm ax)) choices)
    None => AProduct normed

isEmptyAuth : Authority -> Bool
isEmptyAuth (AJoin []) = True
isEmptyAuth _ = False

-- Every tuple of constants the axes span, when no axis holds a variable.
axisConstants : List (String, Authority) -> Option (List (List (String, Param)))
axisConstants [] = Some [[]]
axisConstants ((name, t) :: rest) = match (authConsts t, axisConstants rest)
  (Some ps, Some tails) => Some (flatMap (p => map ((name, p) :: _) tails) ps)
  _ => None

assemble : List Param -> List Authority -> Map Int (Ref Authvar) -> Authority
assemble consts tuples vars =
  match map AConst consts ++ dedupBy termKey tuples ++ map AVar (M.values vars)
    [] => AJoin []
    [m] => m
    ms => AJoin ms

-- A key that identifies a tuple whose axes are normalised: every axis, a top
-- one included, and variables by identity. It reads the axes as they stand,
-- so it never normalises the tuple it keys.
termKey : Authority -> String
termKey (AProduct axes) =
  joinWith
    " "
    (map
      (a =>
        "\{fst a}=\{renderAxisTerm (cell => "#" ++ intToString (authvarId cell)) (snd a)}")
      axes)
termKey _ = ""

-- A value's abstraction may over-approximate it, so a value whose authority
-- would hold more than `setCardCap` constants is folded by the domain join
-- into one element that covers them all; its variables are kept. Only the
-- abstraction α calls this: a bound is never a value's abstraction, so no
-- bound is ever folded.
export
authWidenValue : Authority -> Authority
authWidenValue a =
  let (consts, tuples, vars) = collect [a] (Parts [] [] Tip)
  let cs = dantichain consts
  if listLen cs > setCardCap then
    assemble [fold djoinN (headOr cs) cs] tuples vars
  else
    authNorm a

headOr : List Param -> Param
headOr (p :: _) = p
headOr [] = PUnit

export
authJoin : Authority -> Authority -> Authority
authJoin a b = authNorm (AJoin [a, b])

export
authJoinAll : List Authority -> Authority
authJoinAll ms = authNorm (AJoin ms)

-- The concrete element a term denotes, when it is one constant.
export
authConst : Authority -> Option Param
authConst a = match authNorm a
  AConst p => Some p
  _ => None

-- The constants a term denotes, when it has no variable left: one for a
-- single element, the antichain's members for a set, none for the empty
-- authority.
export
authConsts : Authority -> Option (List Param)
authConsts a = match authNorm a
  AConst p => Some [p]
  AJoin ms => allConsts ms []
  _ => None

allConsts : List Authority -> List Param -> Option (List Param)
allConsts [] acc = Some (reverseL acc)
allConsts ((AConst p) :: ms) acc = allConsts ms (p :: acc)
allConsts _ _ = None

export
authIsTop : Authority -> Bool
authIsTop a = match authNorm a
  AConst p => isSubTop p
  _ => False

-- The unbound variables a term mentions, deduplicated by identity, those on
-- a Product tuple's axes included.
export
authVars : Authority -> List (Ref Authvar)
authVars a = M.values (varsInto a Tip)

varsInto : Authority -> Map Int (Ref Authvar) -> Map Int (Ref Authvar)
varsInto a acc =
  let (_, tuples, vars) = collect [a] (Parts [] [] Tip)
  fold
    (m t => match t
      AProduct axes => fold (m2 ax => varsInto (snd ax) m2) m axes
      _ => m)
    (M.union vars acc)
    tuples

export
authHasVars : Authority -> Bool
authHasVars a = match authVars a
  [] => False
  _ => True

-- `lo ⊑ hi`, decided only where provable now. False means "not proven": the
-- caller decides whether that is a failure or a pending obligation.
export
authSub : Authority -> Authority -> Bool
authSub lo hi = authSubN (authNorm lo) (authNorm hi)

authSubN : Authority -> Authority -> Bool
authSubN (AJoin []) _ = True
authSubN (AConst c) (AConst d) = dsub c d
authSubN _ (AConst d)
  | isSubTop d = True
authSubN (AJoin ms) hi = allSub ms hi
-- One tuple lies within another when each axis does, and a tuple is a single
-- element, so a tuple that holds a variable is within a constant only when
-- that one constant covers it pointwise.
authSubN (AProduct xs) (AConst (PProduct dx)) =
  axesWithin xs (map (a => (fst a, AConst (snd a))) dx)
authSubN _ (AConst _) = False
-- A constant is within a set when some element covers it, or when the
-- elements cover it together (a Product tuple, singleton by singleton).
authSubN (AConst c) (AJoin ms) =
  anySub (AConst c) ms || dsubAny c (constantsOf ms)
authSubN (AConst (PProduct cx)) (AProduct ys) =
  axesWithin (map (a => (fst a, AConst (snd a))) cx) ys
authSubN (AProduct xs) (AProduct ys) = axesWithin xs ys
-- A tuple that holds a variable is within a set only when one element covers
-- it: which tuples several elements cover together depends on the variable.
authSubN lo (AJoin ms) = anySub lo ms
authSubN (AVar v) (AVar w) = authvarId v == authvarId w
authSubN _ _ = False

-- Two tuples of one schema, axis by axis.
axesWithin : List (String, Authority) -> List (String, Authority) -> Bool
axesWithin xs ys =
  map fst xs == map fst ys
    && allList
      (y => match lookupTerm (fst y) xs
        Some x =>
          domainKey (authDomainTop x) == domainKey (authDomainTop (snd y))
            && authSub x (snd y)
        None => False)
      ys

lookupTerm : String -> List (String, Authority) -> Option Authority
lookupTerm _ [] = None
lookupTerm name ((k, t) :: rest) =
  if name == k then Some t else lookupTerm name rest

-- `lo ⊑ hi` as the obligations it is equivalent to. Against a tuple that
-- holds variables it is one obligation per axis, `lo`'s projection on that
-- axis within the tuple's term, which is exact because a tuple of terms
-- denotes a product of sets. A lower term with no projection (a variable of
-- the whole Product domain) keeps the obligation whole, where it is not
-- proven.
export
authSplit : Authority -> Authority -> List (Authority, Authority)
authSplit lo hi = match authNorm hi
  AProduct axes =>
    let schema = domainKey (authDomainTop (AProduct axes))
    match projections schema axes lo
      Some parts => parts
      None => [(lo, hi)]
  _ => [(lo, hi)]

projections : String ->
  List (String, Authority) ->
  Authority ->
  Option (List (Authority, Authority))
projections _ [] _ = Some []
projections schema ((name, t) :: rest) lo = match (
  projectAxis schema name lo,
  projections schema rest lo,
)
  (Some p, Some more) => Some ((p, t) :: more)
  _ => None

-- A term's values on one axis of the Product domain keyed [schema].
projectAxis : String -> String -> Authority -> Option Authority
projectAxis schema name lo = match authNorm lo
  AJoin [] => Some (AJoin [])
  AConst (p@(PProduct ax)) =>
    if domainKey p == schema then map AConst (lookupAxis name ax) else None
  AProduct axes =>
    if domainKey (authDomainTop (AProduct axes)) == schema then
      lookupTerm name axes
    else
      None
  AJoin ms =>
    fold
      (acc m => match (acc, projectAxis schema name m)
        (Some a, Some b) => Some (authJoin a b)
        _ => None)
      (Some (AJoin []))
      ms
  _ => None

constantsOf : List Authority -> List Param
constantsOf [] = []
constantsOf ((AConst p) :: ms) = p :: constantsOf ms
constantsOf (_ :: ms) = constantsOf ms

allSub : List Authority -> Authority -> Bool
allSub [] _ = True
allSub (m :: ms) hi = authSubN m hi && allSub ms hi

anySub : Authority -> List Authority -> Bool
anySub _ [] = False
anySub lo (m :: ms) = authSubN lo m || anySub lo ms

-- Render with a caller-supplied variable namer, so a scheme printer can share
-- its naming context. A join renders its operands separated by ` | `.
export
renderAuthorityWith : (Ref Authvar -> String) -> Authority -> String
renderAuthorityWith name a = match authNorm a
  AJoin [] => " {}"
  AConst p => drender p
  AVar cell => " " ++ name cell
  AJoin ms => " (" ++ joinWith " | " (map (renderOperand name) ms) ++ ")"
  AProduct axes => " " ++ renderTuple name axes

renderOperand : (Ref Authvar -> String) -> Authority -> String
renderOperand _ (AConst p) = trimLeft (drender p)
renderOperand name (AVar cell) = name cell
renderOperand name (AProduct axes) = renderTuple name axes
renderOperand name a = renderAuthorityWith name a

-- A tuple's axes as a signature writes them, a top axis left out.
renderTuple : (Ref Authvar -> String) -> List (String, Authority) -> String
renderTuple name axes =
  joinWith
    " "
    (map
      (a => "\{fst a}=\{renderAxisTerm name (snd a)}")
      (filterList (a => not (authIsTop (snd a))) axes))

renderAxisTerm : (Ref Authvar -> String) -> Authority -> String
renderAxisTerm name t = match authNorm t
  AConst p => renderAxisVal p
  AVar cell => name cell
  AJoin [] => "{}"
  AJoin ms => "(" ++ joinWith " | " (map (renderAxisTerm name) ms) ++ ")"
  AProduct axes => "(" ++ renderTuple name axes ++ ")"

-- The default namer: a binder's own name where the variable came from a
-- signature, else a stable id-based spelling.
export
authvarDefaultName : Ref Authvar -> String
authvarDefaultName cell = match authvarName cell
  Some n => n
  None => "k" ++ intToString (authvarId cell)

export
renderAuthority : Authority -> String
renderAuthority a = renderAuthorityWith authvarDefaultName a

-- A solved authority as the runtime receives it (EFFECTS-SEMANTICS §8): the
-- whole domain, the empty authority, or the domain elements it admits (a
-- trailing `*` spells a pattern) joined with the variables it still names. The
-- empty authority is kept apart from the whole domain, because a runtime that
-- read it as the whole domain would admit what no value ever reached. A
-- Product tuple that still holds a variable has no element spelling, so it
-- widens to the whole domain.
public export data GrantShape =
  | GrantTop
  | GrantBottom
  | GrantParts (List String) (List (Ref Authvar))

export
authGrantShape : Authority -> GrantShape
authGrantShape a = match authNorm a
  AJoin [] => GrantBottom
  AJoin ms => grantJoin ms [] []
  other => grantJoin [other] [] []

grantJoin : List Authority -> List String -> List (Ref Authvar) -> GrantShape
grantJoin [] elems vars = GrantParts (reverseL elems) (reverseL vars)
grantJoin ((AConst p) :: rest) elems vars =
  if isSubTop p then
    GrantTop
  else
    grantJoin rest (reverseL (paramElements p) ++ elems) vars
grantJoin ((AVar cell) :: rest) elems vars = grantJoin rest elems (cell :: vars)
grantJoin _ _ _ = GrantTop

-- The domain spelling of one constant: a Prefix element or pattern, each Set
-- member, or a Product element as a signature writes it.
paramElements : Param -> List String
paramElements (PPrefix (Some s)) = [s]
paramElements (PSet (Some xs)) = xs
paramElements p = [trimLeft (drender p)]
# DESUGAR
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "dsub" false) (mem "canonParam" false) (mem "drender" false) (mem "isSubTop" false) (mem "subTopOf" false) (mem "extendParam" false) (mem "appendParam" false) (mem "dantichain" false) (mem "dsubAny" false) (mem "djoinN" false) (mem "setCardCap" false) (mem "productNorm" false) (mem "renderAxisVal" false) (mem "lookupAxis" false) (mem "domainKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false) (mem "listLen" false) (mem "anyList" false) (mem "allList" false) (mem "dedupBy" false) (mem "filterList" false))))
(DUse false (UseGroup ("string") ((mem "trimLeft" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DData Public "Authority" () ((variant "AConst" (ConPos (TyCon "Param"))) (variant "AVar" (ConPos (TyApp (TyCon "Ref") (TyCon "Authvar")))) (variant "AJoin" (ConPos (TyApp (TyCon "List") (TyCon "Authority")))) (variant "AProduct" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority")))))) ())
(DData Public "Authvar" () ((variant "AUnbound" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Param") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "String")))) (variant "ALink" (ConPos (TyCon "Int") (TyCon "Param") (TyCon "Authority")))) ())
(DTypeSig true "authvarId" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Int")))
(DFunDef false "authvarId" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") PWild PWild PWild PWild) () (EVar "id")) (arm (PCon "ALink" (PVar "id") PWild PWild) () (EVar "id"))))
(DTypeSig true "authvarLevel" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Int")))
(DFunDef false "authvarLevel" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild (PVar "level") PWild PWild PWild) () (EVar "level")) (arm (PCon "ALink" PWild PWild (PVar "a")) () (EApp (EVar "authLevelOf") (EVar "a")))))
(DTypeSig false "authLevelOf" (TyFun (TyCon "Authority") (TyCon "Int")))
(DFunDef false "authLevelOf" ((PCon "AVar" (PVar "cell"))) (EApp (EVar "authvarLevel") (EVar "cell")))
(DFunDef false "authLevelOf" ((PCon "AJoin" (PVar "ms"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "m")) (EApp (EApp (EVar "max") (EVar "acc")) (EApp (EVar "authLevelOf") (EVar "m"))))) (ELit (LInt 0))) (EVar "ms")))
(DFunDef false "authLevelOf" ((PCon "AProduct" (PVar "axes"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "a")) (EApp (EApp (EVar "max") (EVar "acc")) (EApp (EVar "authLevelOf") (EApp (EVar "snd") (EVar "a")))))) (ELit (LInt 0))) (EVar "axes")))
(DFunDef false "authLevelOf" (PWild) (ELit (LInt 0)))
(DTypeSig true "authvarDomain" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Param")))
(DFunDef false "authvarDomain" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild PWild (PVar "top") PWild PWild) () (EVar "top")) (arm (PCon "ALink" PWild (PVar "top") PWild) () (EVar "top"))))
(DTypeSig true "authvarName" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "authvarName" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild PWild PWild PWild (PVar "name")) () (EVar "name")) (arm (PCon "ALink" PWild PWild PWild) () (EVar "None"))))
(DTypeSig true "authvarIsPattern" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Bool")))
(DFunDef false "authvarIsPattern" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild PWild PWild (PVar "pat") PWild) () (EVar "pat")) (arm (PCon "ALink" PWild PWild (PVar "target")) () (EApp (EVar "authIsPattern") (EVar "target")))))
(DTypeSig true "markAuthvarPattern" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Unit")))
(DFunDef false "markAuthvarPattern" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") (PVar "level") (PVar "top") PWild (PVar "name")) () (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "level")) (EVar "top")) (EVar "True")) (EVar "name")))) (arm (PCon "ALink" PWild PWild PWild) () (ELit LUnit))))
(DTypeSig true "linkAuthvar" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyCon "Unit"))))
(DFunDef false "linkAuthvar" ((PVar "cell") (PVar "a")) (EBlock (DoLet false false (PVar "target") (EIf (EApp (EVar "authvarIsPattern") (EVar "cell")) (EApp (EVar "authPatternClose") (EVar "a")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EApp (EVar "ALink") (EApp (EVar "authvarId") (EVar "cell"))) (EApp (EVar "authvarDomain") (EVar "cell"))) (EVar "target"))))))
(DTypeSig true "authPatternClose" (TyFun (TyCon "Authority") (TyCon "Authority")))
(DFunDef false "authPatternClose" ((PVar "a")) (EApp (EApp (EVar "mapConstants") (EVar "extendParam")) (EVar "a")))
(DTypeSig true "authIsPattern" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "authIsPattern" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "isPatternParam") (EVar "p"))) (arm (PCon "AVar" (PVar "cell")) () (EApp (EVar "authvarIsPattern") (EVar "cell"))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EApp (EVar "allList") (EVar "authIsPattern")) (EVar "ms"))) (arm (PCon "AProduct" (PCons (PTuple PWild (PVar "t")) PWild)) () (EApp (EVar "authIsPattern") (EVar "t"))) (arm (PCon "AProduct" (PList)) () (EVar "True"))))
(DTypeSig true "isPatternParam" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "isPatternParam" ((PVar "p")) (EApp (EApp (EVar "dsub") (EApp (EVar "extendParam") (EVar "p"))) (EVar "p")))
(DTypeSig true "authTop" (TyFun (TyCon "Param") (TyCon "Authority")))
(DFunDef false "authTop" ((PVar "top")) (EApp (EVar "AConst") (EApp (EVar "subTopOf") (EVar "top"))))
(DTypeSig true "authExtend" (TyFun (TyCon "Authority") (TyCon "Authority")))
(DFunDef false "authExtend" ((PVar "a")) (EApp (EApp (EVar "mapConstants") (EVar "extendParam")) (EVar "a")))
(DTypeSig true "authAppend" (TyFun (TyCon "String") (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "authAppend" ((PVar "suffix") (PVar "a")) (EApp (EApp (EVar "mapConstants") (EApp (EVar "appendParam") (EVar "suffix"))) (EVar "a")))
(DTypeSig false "mapConstants" (TyFun (TyFun (TyCon "Param") (TyCon "Param")) (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "mapConstants" ((PVar "f") (PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "AConst") (EApp (EVar "f") (EVar "p")))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EVar "authJoinAll") (EApp (EApp (EVar "map") (EApp (EVar "mapConstants") (EVar "f"))) (EVar "ms")))) (arm (PCon "AProduct" (PCons (PTuple (PVar "name") (PVar "t")) (PVar "rest"))) () (EApp (EVar "authNorm") (EApp (EVar "AProduct") (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "mapConstants") (EVar "f")) (EVar "t"))) (EVar "rest"))))) (arm (PCon "AVar" (PVar "cell")) () (EIf (EApp (EVar "authvarIsPattern") (EVar "cell")) (EApp (EVar "AVar") (EVar "cell")) (EApp (EVar "authTop") (EApp (EVar "authvarDomain") (EVar "cell"))))) (arm (PVar "v") () (EVar "v"))))
(DTypeSig true "authDomainTop" (TyFun (TyCon "Authority") (TyCon "Param")))
(DFunDef false "authDomainTop" ((PCon "AConst" (PVar "p"))) (EApp (EVar "subTopOf") (EVar "p")))
(DFunDef false "authDomainTop" ((PCon "AVar" (PVar "cell"))) (EApp (EVar "authvarDomain") (EVar "cell")))
(DFunDef false "authDomainTop" ((PCon "AProduct" (PVar "axes"))) (EApp (EVar "PProduct") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "authDomainTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "axes"))))
(DFunDef false "authDomainTop" ((PCon "AJoin" (PVar "ms"))) (EMatch (EApp (EVar "filterVars") (EVar "ms")) (arm (PCons (PVar "v") PWild) () (EApp (EVar "authDomainTop") (EVar "v"))) (arm (PList) () (EMatch (EVar "ms") (arm (PCons (PVar "m") PWild) () (EApp (EVar "authDomainTop") (EVar "m"))) (arm (PList) () (EVar "PUnit"))))))
(DTypeSig false "filterVars" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyApp (TyCon "List") (TyCon "Authority"))))
(DFunDef false "filterVars" ((PList)) (EListLit))
(DFunDef false "filterVars" ((PCons (PCon "AVar" (PVar "c")) (PVar "ms"))) (EBinOp "::" (EApp (EVar "AVar") (EVar "c")) (EApp (EVar "filterVars") (EVar "ms"))))
(DFunDef false "filterVars" ((PCons PWild (PVar "ms"))) (EApp (EVar "filterVars") (EVar "ms")))
(DTypeSig true "authNorm" (TyFun (TyCon "Authority") (TyCon "Authority")))
(DFunDef false "authNorm" ((PVar "a")) (EBlock (DoLet false false (PTuple (PVar "consts") (PVar "tuples") (PVar "vars")) (EApp (EApp (EVar "collect") (EListLit (EVar "a"))) (EApp (EApp (EApp (EVar "Parts") (EListLit)) (EListLit)) (EVar "Tip")))) (DoExpr (EMatch (EApp (EVar "dantichain") (EVar "consts")) (arm (PList (PVar "c")) () (EIf (EApp (EVar "isSubTop") (EVar "c")) (EApp (EVar "AConst") (EVar "c")) (EApp (EApp (EApp (EVar "assemble") (EListLit (EVar "c"))) (EVar "tuples")) (EVar "vars")))) (arm (PVar "cs") () (EApp (EApp (EApp (EVar "assemble") (EVar "cs")) (EVar "tuples")) (EVar "vars")))))))
(DData Private "Parts" () ((variant "Parts" (ConPos (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Authority")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar")))))) ())
(DTypeSig false "collect" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyCon "Parts") (TyTuple (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Authority")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "collect" ((PList) (PCon "Parts" (PVar "consts") (PVar "tuples") (PVar "vars"))) (ETuple (EVar "consts") (EApp (EVar "reverseL") (EVar "tuples")) (EVar "vars")))
(DFunDef false "collect" ((PCons (PCon "AConst" (PVar "p")) (PVar "rest")) (PCon "Parts" (PVar "consts") (PVar "tuples") (PVar "vars"))) (EApp (EApp (EVar "collect") (EVar "rest")) (EApp (EApp (EApp (EVar "Parts") (EBinOp "::" (EVar "p") (EVar "consts"))) (EVar "tuples")) (EVar "vars"))))
(DFunDef false "collect" ((PCons (PCon "AVar" (PVar "cell")) (PVar "rest")) (PCon "Parts" (PVar "consts") (PVar "tuples") (PVar "vars"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" PWild PWild (PVar "target")) () (EApp (EApp (EVar "collect") (EBinOp "::" (EVar "target") (EVar "rest"))) (EApp (EApp (EApp (EVar "Parts") (EVar "consts")) (EVar "tuples")) (EVar "vars")))) (arm (PCon "AUnbound" (PVar "id") PWild PWild PWild PWild) () (EApp (EApp (EVar "collect") (EVar "rest")) (EApp (EApp (EApp (EVar "Parts") (EVar "consts")) (EVar "tuples")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EVar "vars")))))))
(DFunDef false "collect" ((PCons (PCon "AJoin" (PVar "ms")) (PVar "rest")) (PVar "parts")) (EApp (EApp (EVar "collect") (EBinOp "++" (EVar "ms") (EVar "rest"))) (EVar "parts")))
(DFunDef false "collect" ((PCons (PCon "AProduct" (PVar "axes")) (PVar "rest")) (PCon "Parts" (PVar "consts") (PVar "tuples") (PVar "vars"))) (EMatch (EApp (EVar "productTerm") (EVar "axes")) (arm (PCon "AProduct" (PVar "normed")) () (EApp (EApp (EVar "collect") (EVar "rest")) (EApp (EApp (EApp (EVar "Parts") (EVar "consts")) (EBinOp "::" (EApp (EVar "AProduct") (EVar "normed")) (EVar "tuples"))) (EVar "vars")))) (arm (PVar "other") () (EApp (EApp (EVar "collect") (EBinOp "::" (EVar "other") (EVar "rest"))) (EApp (EApp (EApp (EVar "Parts") (EVar "consts")) (EVar "tuples")) (EVar "vars"))))))
(DTypeSig false "productTerm" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyCon "Authority")))
(DFunDef false "productTerm" ((PVar "axes")) (EBlock (DoLet false false (PVar "normed") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "authNorm") (EApp (EVar "snd") (EVar "a")))))) (EVar "axes"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EVar "isEmptyAuth") (EApp (EVar "snd") (EVar "a"))))) (EVar "normed")) (EApp (EVar "AJoin") (EListLit)) (EMatch (EApp (EVar "axisConstants") (EVar "normed")) (arm (PCon "Some" (PVar "choices")) () (EApp (EVar "AJoin") (EApp (EApp (EVar "map") (ELam ((PVar "ax")) (EApp (EVar "AConst") (EApp (EVar "productNorm") (EVar "ax"))))) (EVar "choices")))) (arm (PCon "None") () (EApp (EVar "AProduct") (EVar "normed"))))))))
(DTypeSig false "isEmptyAuth" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "isEmptyAuth" ((PCon "AJoin" (PList))) (EVar "True"))
(DFunDef false "isEmptyAuth" (PWild) (EVar "False"))
(DTypeSig false "axisConstants" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))))
(DFunDef false "axisConstants" ((PList)) (EApp (EVar "Some") (EListLit (EListLit))))
(DFunDef false "axisConstants" ((PCons (PTuple (PVar "name") (PVar "t")) (PVar "rest"))) (EMatch (ETuple (EApp (EVar "authConsts") (EVar "t")) (EApp (EVar "axisConstants") (EVar "rest"))) (arm (PTuple (PCon "Some" (PVar "ps")) (PCon "Some" (PVar "tails"))) () (EApp (EVar "Some") (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "name") (EVar "p")) (EVar "_s")))) (EVar "tails")))) (EVar "ps")))) (arm PWild () (EVar "None"))))
(DTypeSig false "assemble" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Authority")))))
(DFunDef false "assemble" ((PVar "consts") (PVar "tuples") (PVar "vars")) (EMatch (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "AConst")) (EVar "consts")) (EApp (EApp (EVar "dedupBy") (EVar "termKey")) (EVar "tuples"))) (EApp (EApp (EVar "map") (EVar "AVar")) (EApp (EVar "M.values") (EVar "vars")))) (arm (PList) () (EApp (EVar "AJoin") (EListLit))) (arm (PList (PVar "m")) () (EVar "m")) (arm (PVar "ms") () (EApp (EVar "AJoin") (EVar "ms")))))
(DTypeSig false "termKey" (TyFun (TyCon "Authority") (TyCon "String")))
(DFunDef false "termKey" ((PCon "AProduct" (PVar "axes"))) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "fst") (EVar "a")))) (ELit (LString "="))) (EApp (EVar "display") (EApp (EApp (EVar "renderAxisTerm") (ELam ((PVar "cell")) (EBinOp "++" (ELit (LString "#")) (EApp (EVar "intToString") (EApp (EVar "authvarId") (EVar "cell")))))) (EApp (EVar "snd") (EVar "a"))))) (ELit (LString ""))))) (EVar "axes"))))
(DFunDef false "termKey" (PWild) (ELit (LString "")))
(DTypeSig true "authWidenValue" (TyFun (TyCon "Authority") (TyCon "Authority")))
(DFunDef false "authWidenValue" ((PVar "a")) (EBlock (DoLet false false (PTuple (PVar "consts") (PVar "tuples") (PVar "vars")) (EApp (EApp (EVar "collect") (EListLit (EVar "a"))) (EApp (EApp (EApp (EVar "Parts") (EListLit)) (EListLit)) (EVar "Tip")))) (DoLet false false (PVar "cs") (EApp (EVar "dantichain") (EVar "consts"))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "cs")) (EVar "setCardCap")) (EApp (EApp (EApp (EVar "assemble") (EListLit (EApp (EApp (EApp (EVar "fold") (EVar "djoinN")) (EApp (EVar "headOr") (EVar "cs"))) (EVar "cs")))) (EVar "tuples")) (EVar "vars")) (EApp (EVar "authNorm") (EVar "a"))))))
(DTypeSig false "headOr" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Param")))
(DFunDef false "headOr" ((PCons (PVar "p") PWild)) (EVar "p"))
(DFunDef false "headOr" ((PList)) (EVar "PUnit"))
(DTypeSig true "authJoin" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "authJoin" ((PVar "a") (PVar "b")) (EApp (EVar "authNorm") (EApp (EVar "AJoin") (EListLit (EVar "a") (EVar "b")))))
(DTypeSig true "authJoinAll" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Authority")))
(DFunDef false "authJoinAll" ((PVar "ms")) (EApp (EVar "authNorm") (EApp (EVar "AJoin") (EVar "ms"))))
(DTypeSig true "authConst" (TyFun (TyCon "Authority") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "authConst" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "Some") (EVar "p"))) (arm PWild () (EVar "None"))))
(DTypeSig true "authConsts" (TyFun (TyCon "Authority") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "authConsts" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "Some") (EListLit (EVar "p")))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EApp (EVar "allConsts") (EVar "ms")) (EListLit))) (arm PWild () (EVar "None"))))
(DTypeSig false "allConsts" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Param"))))))
(DFunDef false "allConsts" ((PList) (PVar "acc")) (EApp (EVar "Some") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "allConsts" ((PCons (PCon "AConst" (PVar "p")) (PVar "ms")) (PVar "acc")) (EApp (EApp (EVar "allConsts") (EVar "ms")) (EBinOp "::" (EVar "p") (EVar "acc"))))
(DFunDef false "allConsts" (PWild PWild) (EVar "None"))
(DTypeSig true "authIsTop" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "authIsTop" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "isSubTop") (EVar "p"))) (arm PWild () (EVar "False"))))
(DTypeSig true "authVars" (TyFun (TyCon "Authority") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar")))))
(DFunDef false "authVars" ((PVar "a")) (EApp (EVar "M.values") (EApp (EApp (EVar "varsInto") (EVar "a")) (EVar "Tip"))))
(DTypeSig false "varsInto" (TyFun (TyCon "Authority") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "varsInto" ((PVar "a") (PVar "acc")) (EBlock (DoLet false false (PTuple PWild (PVar "tuples") (PVar "vars")) (EApp (EApp (EVar "collect") (EListLit (EVar "a"))) (EApp (EApp (EApp (EVar "Parts") (EListLit)) (EListLit)) (EVar "Tip")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "t")) (EMatch (EVar "t") (arm (PCon "AProduct" (PVar "axes")) () (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m2") (PVar "ax")) (EApp (EApp (EVar "varsInto") (EApp (EVar "snd") (EVar "ax"))) (EVar "m2")))) (EVar "m")) (EVar "axes"))) (arm PWild () (EVar "m"))))) (EApp (EApp (EVar "M.union") (EVar "vars")) (EVar "acc"))) (EVar "tuples")))))
(DTypeSig true "authHasVars" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "authHasVars" ((PVar "a")) (EMatch (EApp (EVar "authVars") (EVar "a")) (arm (PList) () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig true "authSub" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "authSub" ((PVar "lo") (PVar "hi")) (EApp (EApp (EVar "authSubN") (EApp (EVar "authNorm") (EVar "lo"))) (EApp (EVar "authNorm") (EVar "hi"))))
(DTypeSig false "authSubN" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "authSubN" ((PCon "AJoin" (PList)) PWild) (EVar "True"))
(DFunDef false "authSubN" ((PCon "AConst" (PVar "c")) (PCon "AConst" (PVar "d"))) (EApp (EApp (EVar "dsub") (EVar "c")) (EVar "d")))
(DFunDef false "authSubN" (PWild (PCon "AConst" (PVar "d"))) (EIf (EApp (EVar "isSubTop") (EVar "d")) (EVar "True") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "authSubN" ((PCon "AJoin" (PVar "ms")) (PVar "hi")) (EApp (EApp (EVar "allSub") (EVar "ms")) (EVar "hi")))
(DFunDef false "authSubN" ((PCon "AProduct" (PVar "xs")) (PCon "AConst" (PCon "PProduct" (PVar "dx")))) (EApp (EApp (EVar "axesWithin") (EVar "xs")) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "AConst") (EApp (EVar "snd") (EVar "a")))))) (EVar "dx"))))
(DFunDef false "authSubN" (PWild (PCon "AConst" PWild)) (EVar "False"))
(DFunDef false "authSubN" ((PCon "AConst" (PVar "c")) (PCon "AJoin" (PVar "ms"))) (EBinOp "||" (EApp (EApp (EVar "anySub") (EApp (EVar "AConst") (EVar "c"))) (EVar "ms")) (EApp (EApp (EVar "dsubAny") (EVar "c")) (EApp (EVar "constantsOf") (EVar "ms")))))
(DFunDef false "authSubN" ((PCon "AConst" (PCon "PProduct" (PVar "cx"))) (PCon "AProduct" (PVar "ys"))) (EApp (EApp (EVar "axesWithin") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "AConst") (EApp (EVar "snd") (EVar "a")))))) (EVar "cx"))) (EVar "ys")))
(DFunDef false "authSubN" ((PCon "AProduct" (PVar "xs")) (PCon "AProduct" (PVar "ys"))) (EApp (EApp (EVar "axesWithin") (EVar "xs")) (EVar "ys")))
(DFunDef false "authSubN" ((PVar "lo") (PCon "AJoin" (PVar "ms"))) (EApp (EApp (EVar "anySub") (EVar "lo")) (EVar "ms")))
(DFunDef false "authSubN" ((PCon "AVar" (PVar "v")) (PCon "AVar" (PVar "w"))) (EBinOp "==" (EApp (EVar "authvarId") (EVar "v")) (EApp (EVar "authvarId") (EVar "w"))))
(DFunDef false "authSubN" (PWild PWild) (EVar "False"))
(DTypeSig false "axesWithin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyCon "Bool"))))
(DFunDef false "axesWithin" ((PVar "xs") (PVar "ys")) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "xs")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ys"))) (EApp (EApp (EVar "allList") (ELam ((PVar "y")) (EMatch (EApp (EApp (EVar "lookupTerm") (EApp (EVar "fst") (EVar "y"))) (EVar "xs")) (arm (PCon "Some" (PVar "x")) () (EBinOp "&&" (EBinOp "==" (EApp (EVar "domainKey") (EApp (EVar "authDomainTop") (EVar "x"))) (EApp (EVar "domainKey") (EApp (EVar "authDomainTop") (EApp (EVar "snd") (EVar "y"))))) (EApp (EApp (EVar "authSub") (EVar "x")) (EApp (EVar "snd") (EVar "y"))))) (arm (PCon "None") () (EVar "False"))))) (EVar "ys"))))
(DTypeSig false "lookupTerm" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyApp (TyCon "Option") (TyCon "Authority")))))
(DFunDef false "lookupTerm" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupTerm" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "t")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "k")) (EApp (EVar "Some") (EVar "t")) (EApp (EApp (EVar "lookupTerm") (EVar "name")) (EVar "rest"))))
(DTypeSig true "authSplit" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyApp (TyCon "List") (TyTuple (TyCon "Authority") (TyCon "Authority"))))))
(DFunDef false "authSplit" ((PVar "lo") (PVar "hi")) (EMatch (EApp (EVar "authNorm") (EVar "hi")) (arm (PCon "AProduct" (PVar "axes")) () (EBlock (DoLet false false (PVar "schema") (EApp (EVar "domainKey") (EApp (EVar "authDomainTop") (EApp (EVar "AProduct") (EVar "axes"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "projections") (EVar "schema")) (EVar "axes")) (EVar "lo")) (arm (PCon "Some" (PVar "parts")) () (EVar "parts")) (arm (PCon "None") () (EListLit (ETuple (EVar "lo") (EVar "hi")))))))) (arm PWild () (EListLit (ETuple (EVar "lo") (EVar "hi"))))))
(DTypeSig false "projections" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyFun (TyCon "Authority") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Authority") (TyCon "Authority"))))))))
(DFunDef false "projections" (PWild (PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "projections" ((PVar "schema") (PCons (PTuple (PVar "name") (PVar "t")) (PVar "rest")) (PVar "lo")) (EMatch (ETuple (EApp (EApp (EApp (EVar "projectAxis") (EVar "schema")) (EVar "name")) (EVar "lo")) (EApp (EApp (EApp (EVar "projections") (EVar "schema")) (EVar "rest")) (EVar "lo"))) (arm (PTuple (PCon "Some" (PVar "p")) (PCon "Some" (PVar "more"))) () (EApp (EVar "Some") (EBinOp "::" (ETuple (EVar "p") (EVar "t")) (EVar "more")))) (arm PWild () (EVar "None"))))
(DTypeSig false "projectAxis" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Authority") (TyApp (TyCon "Option") (TyCon "Authority"))))))
(DFunDef false "projectAxis" ((PVar "schema") (PVar "name") (PVar "lo")) (EMatch (EApp (EVar "authNorm") (EVar "lo")) (arm (PCon "AJoin" (PList)) () (EApp (EVar "Some") (EApp (EVar "AJoin") (EListLit)))) (arm (PCon "AConst" (PAs "p" (PCon "PProduct" (PVar "ax")))) () (EIf (EBinOp "==" (EApp (EVar "domainKey") (EVar "p")) (EVar "schema")) (EApp (EApp (EVar "map") (EVar "AConst")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax"))) (EVar "None"))) (arm (PCon "AProduct" (PVar "axes")) () (EIf (EBinOp "==" (EApp (EVar "domainKey") (EApp (EVar "authDomainTop") (EApp (EVar "AProduct") (EVar "axes")))) (EVar "schema")) (EApp (EApp (EVar "lookupTerm") (EVar "name")) (EVar "axes")) (EVar "None"))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "m")) (EMatch (ETuple (EVar "acc") (EApp (EApp (EApp (EVar "projectAxis") (EVar "schema")) (EVar "name")) (EVar "m"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EApp (EVar "authJoin") (EVar "a")) (EVar "b")))) (arm PWild () (EVar "None"))))) (EApp (EVar "Some") (EApp (EVar "AJoin") (EListLit)))) (EVar "ms"))) (arm PWild () (EVar "None"))))
(DTypeSig false "constantsOf" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "constantsOf" ((PList)) (EListLit))
(DFunDef false "constantsOf" ((PCons (PCon "AConst" (PVar "p")) (PVar "ms"))) (EBinOp "::" (EVar "p") (EApp (EVar "constantsOf") (EVar "ms"))))
(DFunDef false "constantsOf" ((PCons PWild (PVar "ms"))) (EApp (EVar "constantsOf") (EVar "ms")))
(DTypeSig false "allSub" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "allSub" ((PList) PWild) (EVar "True"))
(DFunDef false "allSub" ((PCons (PVar "m") (PVar "ms")) (PVar "hi")) (EBinOp "&&" (EApp (EApp (EVar "authSubN") (EVar "m")) (EVar "hi")) (EApp (EApp (EVar "allSub") (EVar "ms")) (EVar "hi"))))
(DTypeSig false "anySub" (TyFun (TyCon "Authority") (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Bool"))))
(DFunDef false "anySub" (PWild (PList)) (EVar "False"))
(DFunDef false "anySub" ((PVar "lo") (PCons (PVar "m") (PVar "ms"))) (EBinOp "||" (EApp (EApp (EVar "authSubN") (EVar "lo")) (EVar "m")) (EApp (EApp (EVar "anySub") (EVar "lo")) (EVar "ms"))))
(DTypeSig true "renderAuthorityWith" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "renderAuthorityWith" ((PVar "name") (PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AJoin" (PList)) () (ELit (LString " {}"))) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "drender") (EVar "p"))) (arm (PCon "AVar" (PVar "cell")) () (EBinOp "++" (ELit (LString " ")) (EApp (EVar "name") (EVar "cell")))) (arm (PCon "AJoin" (PVar "ms")) () (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EVar "map") (EApp (EVar "renderOperand") (EVar "name"))) (EVar "ms")))) (ELit (LString ")")))) (arm (PCon "AProduct" (PVar "axes")) () (EBinOp "++" (ELit (LString " ")) (EApp (EApp (EVar "renderTuple") (EVar "name")) (EVar "axes"))))))
(DTypeSig false "renderOperand" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "renderOperand" (PWild (PCon "AConst" (PVar "p"))) (EApp (EVar "trimLeft") (EApp (EVar "drender") (EVar "p"))))
(DFunDef false "renderOperand" ((PVar "name") (PCon "AVar" (PVar "cell"))) (EApp (EVar "name") (EVar "cell")))
(DFunDef false "renderOperand" ((PVar "name") (PCon "AProduct" (PVar "axes"))) (EApp (EApp (EVar "renderTuple") (EVar "name")) (EVar "axes")))
(DFunDef false "renderOperand" ((PVar "name") (PVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "name")) (EVar "a")))
(DTypeSig false "renderTuple" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyCon "String"))))
(DFunDef false "renderTuple" ((PVar "name") (PVar "axes")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "fst") (EVar "a")))) (ELit (LString "="))) (EApp (EVar "display") (EApp (EApp (EVar "renderAxisTerm") (EVar "name")) (EApp (EVar "snd") (EVar "a"))))) (ELit (LString ""))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EApp (EVar "not") (EApp (EVar "authIsTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "axes")))))
(DTypeSig false "renderAxisTerm" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "renderAxisTerm" ((PVar "name") (PVar "t")) (EMatch (EApp (EVar "authNorm") (EVar "t")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "renderAxisVal") (EVar "p"))) (arm (PCon "AVar" (PVar "cell")) () (EApp (EVar "name") (EVar "cell"))) (arm (PCon "AJoin" (PList)) () (ELit (LString "{}"))) (arm (PCon "AJoin" (PVar "ms")) () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EVar "map") (EApp (EVar "renderAxisTerm") (EVar "name"))) (EVar "ms")))) (ELit (LString ")")))) (arm (PCon "AProduct" (PVar "axes")) () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "renderTuple") (EVar "name")) (EVar "axes"))) (ELit (LString ")"))))))
(DTypeSig true "authvarDefaultName" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")))
(DFunDef false "authvarDefaultName" ((PVar "cell")) (EMatch (EApp (EVar "authvarName") (EVar "cell")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (EBinOp "++" (ELit (LString "k")) (EApp (EVar "intToString") (EApp (EVar "authvarId") (EVar "cell")))))))
(DTypeSig true "renderAuthority" (TyFun (TyCon "Authority") (TyCon "String")))
(DFunDef false "renderAuthority" ((PVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "authvarDefaultName")) (EVar "a")))
(DData Public "GrantShape" () ((variant "GrantTop" (ConPos)) (variant "GrantBottom" (ConPos)) (variant "GrantParts" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar")))))) ())
(DTypeSig true "authGrantShape" (TyFun (TyCon "Authority") (TyCon "GrantShape")))
(DFunDef false "authGrantShape" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AJoin" (PList)) () (EVar "GrantBottom")) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EApp (EApp (EVar "grantJoin") (EVar "ms")) (EListLit)) (EListLit))) (arm (PVar "other") () (EApp (EApp (EApp (EVar "grantJoin") (EListLit (EVar "other"))) (EListLit)) (EListLit)))))
(DTypeSig false "grantJoin" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "GrantShape")))))
(DFunDef false "grantJoin" ((PList) (PVar "elems") (PVar "vars")) (EApp (EApp (EVar "GrantParts") (EApp (EVar "reverseL") (EVar "elems"))) (EApp (EVar "reverseL") (EVar "vars"))))
(DFunDef false "grantJoin" ((PCons (PCon "AConst" (PVar "p")) (PVar "rest")) (PVar "elems") (PVar "vars")) (EIf (EApp (EVar "isSubTop") (EVar "p")) (EVar "GrantTop") (EApp (EApp (EApp (EVar "grantJoin") (EVar "rest")) (EBinOp "++" (EApp (EVar "reverseL") (EApp (EVar "paramElements") (EVar "p"))) (EVar "elems"))) (EVar "vars"))))
(DFunDef false "grantJoin" ((PCons (PCon "AVar" (PVar "cell")) (PVar "rest")) (PVar "elems") (PVar "vars")) (EApp (EApp (EApp (EVar "grantJoin") (EVar "rest")) (EVar "elems")) (EBinOp "::" (EVar "cell") (EVar "vars"))))
(DFunDef false "grantJoin" (PWild PWild PWild) (EVar "GrantTop"))
(DTypeSig false "paramElements" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramElements" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EListLit (EVar "s")))
(DFunDef false "paramElements" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EVar "xs"))
(DFunDef false "paramElements" ((PVar "p")) (EListLit (EApp (EVar "trimLeft") (EApp (EVar "drender") (EVar "p")))))
# MARK
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "dsub" false) (mem "canonParam" false) (mem "drender" false) (mem "isSubTop" false) (mem "subTopOf" false) (mem "extendParam" false) (mem "appendParam" false) (mem "dantichain" false) (mem "dsubAny" false) (mem "djoinN" false) (mem "setCardCap" false) (mem "productNorm" false) (mem "renderAxisVal" false) (mem "lookupAxis" false) (mem "domainKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "reverseL" false) (mem "listLen" false) (mem "anyList" false) (mem "allList" false) (mem "dedupBy" false) (mem "filterList" false))))
(DUse false (UseGroup ("string") ((mem "trimLeft" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DData Public "Authority" () ((variant "AConst" (ConPos (TyCon "Param"))) (variant "AVar" (ConPos (TyApp (TyCon "Ref") (TyCon "Authvar")))) (variant "AJoin" (ConPos (TyApp (TyCon "List") (TyCon "Authority")))) (variant "AProduct" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority")))))) ())
(DData Public "Authvar" () ((variant "AUnbound" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Param") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "String")))) (variant "ALink" (ConPos (TyCon "Int") (TyCon "Param") (TyCon "Authority")))) ())
(DTypeSig true "authvarId" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Int")))
(DFunDef false "authvarId" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") PWild PWild PWild PWild) () (EVar "id")) (arm (PCon "ALink" (PVar "id") PWild PWild) () (EVar "id"))))
(DTypeSig true "authvarLevel" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Int")))
(DFunDef false "authvarLevel" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild (PVar "level") PWild PWild PWild) () (EVar "level")) (arm (PCon "ALink" PWild PWild (PVar "a")) () (EApp (EVar "authLevelOf") (EVar "a")))))
(DTypeSig false "authLevelOf" (TyFun (TyCon "Authority") (TyCon "Int")))
(DFunDef false "authLevelOf" ((PCon "AVar" (PVar "cell"))) (EApp (EVar "authvarLevel") (EVar "cell")))
(DFunDef false "authLevelOf" ((PCon "AJoin" (PVar "ms"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "m")) (EApp (EApp (EMethodRef "max") (EVar "acc")) (EApp (EVar "authLevelOf") (EVar "m"))))) (ELit (LInt 0))) (EVar "ms")))
(DFunDef false "authLevelOf" ((PCon "AProduct" (PVar "axes"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "a")) (EApp (EApp (EMethodRef "max") (EVar "acc")) (EApp (EVar "authLevelOf") (EApp (EVar "snd") (EVar "a")))))) (ELit (LInt 0))) (EVar "axes")))
(DFunDef false "authLevelOf" (PWild) (ELit (LInt 0)))
(DTypeSig true "authvarDomain" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Param")))
(DFunDef false "authvarDomain" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild PWild (PVar "top") PWild PWild) () (EVar "top")) (arm (PCon "ALink" PWild (PVar "top") PWild) () (EVar "top"))))
(DTypeSig true "authvarName" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "authvarName" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild PWild PWild PWild (PVar "name")) () (EVar "name")) (arm (PCon "ALink" PWild PWild PWild) () (EVar "None"))))
(DTypeSig true "authvarIsPattern" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Bool")))
(DFunDef false "authvarIsPattern" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" PWild PWild PWild (PVar "pat") PWild) () (EVar "pat")) (arm (PCon "ALink" PWild PWild (PVar "target")) () (EApp (EVar "authIsPattern") (EVar "target")))))
(DTypeSig true "markAuthvarPattern" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Unit")))
(DFunDef false "markAuthvarPattern" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") (PVar "level") (PVar "top") PWild (PVar "name")) () (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "level")) (EVar "top")) (EVar "True")) (EVar "name")))) (arm (PCon "ALink" PWild PWild PWild) () (ELit LUnit))))
(DTypeSig true "linkAuthvar" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyCon "Unit"))))
(DFunDef false "linkAuthvar" ((PVar "cell") (PVar "a")) (EBlock (DoLet false false (PVar "target") (EIf (EApp (EVar "authvarIsPattern") (EVar "cell")) (EApp (EVar "authPatternClose") (EVar "a")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EApp (EVar "ALink") (EApp (EVar "authvarId") (EVar "cell"))) (EApp (EVar "authvarDomain") (EVar "cell"))) (EVar "target"))))))
(DTypeSig true "authPatternClose" (TyFun (TyCon "Authority") (TyCon "Authority")))
(DFunDef false "authPatternClose" ((PVar "a")) (EApp (EApp (EVar "mapConstants") (EVar "extendParam")) (EVar "a")))
(DTypeSig true "authIsPattern" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "authIsPattern" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "isPatternParam") (EVar "p"))) (arm (PCon "AVar" (PVar "cell")) () (EApp (EVar "authvarIsPattern") (EVar "cell"))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EApp (EVar "allList") (EVar "authIsPattern")) (EVar "ms"))) (arm (PCon "AProduct" (PCons (PTuple PWild (PVar "t")) PWild)) () (EApp (EVar "authIsPattern") (EVar "t"))) (arm (PCon "AProduct" (PList)) () (EVar "True"))))
(DTypeSig true "isPatternParam" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "isPatternParam" ((PVar "p")) (EApp (EApp (EVar "dsub") (EApp (EVar "extendParam") (EVar "p"))) (EVar "p")))
(DTypeSig true "authTop" (TyFun (TyCon "Param") (TyCon "Authority")))
(DFunDef false "authTop" ((PVar "top")) (EApp (EVar "AConst") (EApp (EVar "subTopOf") (EVar "top"))))
(DTypeSig true "authExtend" (TyFun (TyCon "Authority") (TyCon "Authority")))
(DFunDef false "authExtend" ((PVar "a")) (EApp (EApp (EVar "mapConstants") (EVar "extendParam")) (EVar "a")))
(DTypeSig true "authAppend" (TyFun (TyCon "String") (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "authAppend" ((PVar "suffix") (PVar "a")) (EApp (EApp (EVar "mapConstants") (EApp (EVar "appendParam") (EVar "suffix"))) (EVar "a")))
(DTypeSig false "mapConstants" (TyFun (TyFun (TyCon "Param") (TyCon "Param")) (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "mapConstants" ((PVar "f") (PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "AConst") (EApp (EVar "f") (EVar "p")))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EVar "authJoinAll") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapConstants") (EVar "f"))) (EVar "ms")))) (arm (PCon "AProduct" (PCons (PTuple (PVar "name") (PVar "t")) (PVar "rest"))) () (EApp (EVar "authNorm") (EApp (EVar "AProduct") (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "mapConstants") (EVar "f")) (EVar "t"))) (EVar "rest"))))) (arm (PCon "AVar" (PVar "cell")) () (EIf (EApp (EVar "authvarIsPattern") (EVar "cell")) (EApp (EVar "AVar") (EVar "cell")) (EApp (EVar "authTop") (EApp (EVar "authvarDomain") (EVar "cell"))))) (arm (PVar "v") () (EVar "v"))))
(DTypeSig true "authDomainTop" (TyFun (TyCon "Authority") (TyCon "Param")))
(DFunDef false "authDomainTop" ((PCon "AConst" (PVar "p"))) (EApp (EVar "subTopOf") (EVar "p")))
(DFunDef false "authDomainTop" ((PCon "AVar" (PVar "cell"))) (EApp (EVar "authvarDomain") (EVar "cell")))
(DFunDef false "authDomainTop" ((PCon "AProduct" (PVar "axes"))) (EApp (EVar "PProduct") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "authDomainTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "axes"))))
(DFunDef false "authDomainTop" ((PCon "AJoin" (PVar "ms"))) (EMatch (EApp (EVar "filterVars") (EVar "ms")) (arm (PCons (PVar "v") PWild) () (EApp (EVar "authDomainTop") (EVar "v"))) (arm (PList) () (EMatch (EVar "ms") (arm (PCons (PVar "m") PWild) () (EApp (EVar "authDomainTop") (EVar "m"))) (arm (PList) () (EVar "PUnit"))))))
(DTypeSig false "filterVars" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyApp (TyCon "List") (TyCon "Authority"))))
(DFunDef false "filterVars" ((PList)) (EListLit))
(DFunDef false "filterVars" ((PCons (PCon "AVar" (PVar "c")) (PVar "ms"))) (EBinOp "::" (EApp (EVar "AVar") (EVar "c")) (EApp (EVar "filterVars") (EVar "ms"))))
(DFunDef false "filterVars" ((PCons PWild (PVar "ms"))) (EApp (EVar "filterVars") (EVar "ms")))
(DTypeSig true "authNorm" (TyFun (TyCon "Authority") (TyCon "Authority")))
(DFunDef false "authNorm" ((PVar "a")) (EBlock (DoLet false false (PTuple (PVar "consts") (PVar "tuples") (PVar "vars")) (EApp (EApp (EVar "collect") (EListLit (EVar "a"))) (EApp (EApp (EApp (EVar "Parts") (EListLit)) (EListLit)) (EVar "Tip")))) (DoExpr (EMatch (EApp (EVar "dantichain") (EVar "consts")) (arm (PList (PVar "c")) () (EIf (EApp (EVar "isSubTop") (EVar "c")) (EApp (EVar "AConst") (EVar "c")) (EApp (EApp (EApp (EVar "assemble") (EListLit (EVar "c"))) (EVar "tuples")) (EVar "vars")))) (arm (PVar "cs") () (EApp (EApp (EApp (EVar "assemble") (EVar "cs")) (EVar "tuples")) (EVar "vars")))))))
(DData Private "Parts" () ((variant "Parts" (ConPos (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Authority")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar")))))) ())
(DTypeSig false "collect" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyCon "Parts") (TyTuple (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "Authority")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "collect" ((PList) (PCon "Parts" (PVar "consts") (PVar "tuples") (PVar "vars"))) (ETuple (EVar "consts") (EApp (EVar "reverseL") (EVar "tuples")) (EVar "vars")))
(DFunDef false "collect" ((PCons (PCon "AConst" (PVar "p")) (PVar "rest")) (PCon "Parts" (PVar "consts") (PVar "tuples") (PVar "vars"))) (EApp (EApp (EVar "collect") (EVar "rest")) (EApp (EApp (EApp (EVar "Parts") (EBinOp "::" (EVar "p") (EVar "consts"))) (EVar "tuples")) (EVar "vars"))))
(DFunDef false "collect" ((PCons (PCon "AVar" (PVar "cell")) (PVar "rest")) (PCon "Parts" (PVar "consts") (PVar "tuples") (PVar "vars"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" PWild PWild (PVar "target")) () (EApp (EApp (EVar "collect") (EBinOp "::" (EVar "target") (EVar "rest"))) (EApp (EApp (EApp (EVar "Parts") (EVar "consts")) (EVar "tuples")) (EVar "vars")))) (arm (PCon "AUnbound" (PVar "id") PWild PWild PWild PWild) () (EApp (EApp (EVar "collect") (EVar "rest")) (EApp (EApp (EApp (EVar "Parts") (EVar "consts")) (EVar "tuples")) (EApp (EApp (EApp (EVar "M.set") (EVar "id")) (EVar "cell")) (EVar "vars")))))))
(DFunDef false "collect" ((PCons (PCon "AJoin" (PVar "ms")) (PVar "rest")) (PVar "parts")) (EApp (EApp (EVar "collect") (EBinOp "++" (EVar "ms") (EVar "rest"))) (EVar "parts")))
(DFunDef false "collect" ((PCons (PCon "AProduct" (PVar "axes")) (PVar "rest")) (PCon "Parts" (PVar "consts") (PVar "tuples") (PVar "vars"))) (EMatch (EApp (EVar "productTerm") (EVar "axes")) (arm (PCon "AProduct" (PVar "normed")) () (EApp (EApp (EVar "collect") (EVar "rest")) (EApp (EApp (EApp (EVar "Parts") (EVar "consts")) (EBinOp "::" (EApp (EVar "AProduct") (EVar "normed")) (EVar "tuples"))) (EVar "vars")))) (arm (PVar "other") () (EApp (EApp (EVar "collect") (EBinOp "::" (EVar "other") (EVar "rest"))) (EApp (EApp (EApp (EVar "Parts") (EVar "consts")) (EVar "tuples")) (EVar "vars"))))))
(DTypeSig false "productTerm" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyCon "Authority")))
(DFunDef false "productTerm" ((PVar "axes")) (EBlock (DoLet false false (PVar "normed") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "authNorm") (EApp (EVar "snd") (EVar "a")))))) (EVar "axes"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EVar "isEmptyAuth") (EApp (EVar "snd") (EVar "a"))))) (EVar "normed")) (EApp (EVar "AJoin") (EListLit)) (EMatch (EApp (EVar "axisConstants") (EVar "normed")) (arm (PCon "Some" (PVar "choices")) () (EApp (EVar "AJoin") (EApp (EApp (EMethodRef "map") (ELam ((PVar "ax")) (EApp (EVar "AConst") (EApp (EVar "productNorm") (EVar "ax"))))) (EVar "choices")))) (arm (PCon "None") () (EApp (EVar "AProduct") (EVar "normed"))))))))
(DTypeSig false "isEmptyAuth" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "isEmptyAuth" ((PCon "AJoin" (PList))) (EVar "True"))
(DFunDef false "isEmptyAuth" (PWild) (EVar "False"))
(DTypeSig false "axisConstants" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param")))))))
(DFunDef false "axisConstants" ((PList)) (EApp (EVar "Some") (EListLit (EListLit))))
(DFunDef false "axisConstants" ((PCons (PTuple (PVar "name") (PVar "t")) (PVar "rest"))) (EMatch (ETuple (EApp (EVar "authConsts") (EVar "t")) (EApp (EVar "axisConstants") (EVar "rest"))) (arm (PTuple (PCon "Some" (PVar "ps")) (PCon "Some" (PVar "tails"))) () (EApp (EVar "Some") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "name") (EVar "p")) (EVar "_s")))) (EVar "tails")))) (EVar "ps")))) (arm PWild () (EVar "None"))))
(DTypeSig false "assemble" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Authority")))))
(DFunDef false "assemble" ((PVar "consts") (PVar "tuples") (PVar "vars")) (EMatch (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "AConst")) (EVar "consts")) (EApp (EApp (EVar "dedupBy") (EVar "termKey")) (EVar "tuples"))) (EApp (EApp (EMethodRef "map") (EVar "AVar")) (EApp (EVar "M.values") (EVar "vars")))) (arm (PList) () (EApp (EVar "AJoin") (EListLit))) (arm (PList (PVar "m")) () (EVar "m")) (arm (PVar "ms") () (EApp (EVar "AJoin") (EVar "ms")))))
(DTypeSig false "termKey" (TyFun (TyCon "Authority") (TyCon "String")))
(DFunDef false "termKey" ((PCon "AProduct" (PVar "axes"))) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "a")))) (ELit (LString "="))) (EApp (EMethodRef "display") (EApp (EApp (EVar "renderAxisTerm") (ELam ((PVar "cell")) (EBinOp "++" (ELit (LString "#")) (EApp (EVar "intToString") (EApp (EVar "authvarId") (EVar "cell")))))) (EApp (EVar "snd") (EVar "a"))))) (ELit (LString ""))))) (EVar "axes"))))
(DFunDef false "termKey" (PWild) (ELit (LString "")))
(DTypeSig true "authWidenValue" (TyFun (TyCon "Authority") (TyCon "Authority")))
(DFunDef false "authWidenValue" ((PVar "a")) (EBlock (DoLet false false (PTuple (PVar "consts") (PVar "tuples") (PVar "vars")) (EApp (EApp (EVar "collect") (EListLit (EVar "a"))) (EApp (EApp (EApp (EVar "Parts") (EListLit)) (EListLit)) (EVar "Tip")))) (DoLet false false (PVar "cs") (EApp (EVar "dantichain") (EVar "consts"))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "cs")) (EVar "setCardCap")) (EApp (EApp (EApp (EVar "assemble") (EListLit (EApp (EApp (EApp (EMethodRef "fold") (EVar "djoinN")) (EApp (EVar "headOr") (EVar "cs"))) (EVar "cs")))) (EVar "tuples")) (EVar "vars")) (EApp (EVar "authNorm") (EVar "a"))))))
(DTypeSig false "headOr" (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyCon "Param")))
(DFunDef false "headOr" ((PCons (PVar "p") PWild)) (EVar "p"))
(DFunDef false "headOr" ((PList)) (EVar "PUnit"))
(DTypeSig true "authJoin" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "authJoin" ((PVar "a") (PVar "b")) (EApp (EVar "authNorm") (EApp (EVar "AJoin") (EListLit (EVar "a") (EVar "b")))))
(DTypeSig true "authJoinAll" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Authority")))
(DFunDef false "authJoinAll" ((PVar "ms")) (EApp (EVar "authNorm") (EApp (EVar "AJoin") (EVar "ms"))))
(DTypeSig true "authConst" (TyFun (TyCon "Authority") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "authConst" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "Some") (EVar "p"))) (arm PWild () (EVar "None"))))
(DTypeSig true "authConsts" (TyFun (TyCon "Authority") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Param")))))
(DFunDef false "authConsts" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "Some") (EListLit (EVar "p")))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EApp (EVar "allConsts") (EVar "ms")) (EListLit))) (arm PWild () (EVar "None"))))
(DTypeSig false "allConsts" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyApp (TyCon "List") (TyCon "Param")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Param"))))))
(DFunDef false "allConsts" ((PList) (PVar "acc")) (EApp (EVar "Some") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "allConsts" ((PCons (PCon "AConst" (PVar "p")) (PVar "ms")) (PVar "acc")) (EApp (EApp (EVar "allConsts") (EVar "ms")) (EBinOp "::" (EVar "p") (EVar "acc"))))
(DFunDef false "allConsts" (PWild PWild) (EVar "None"))
(DTypeSig true "authIsTop" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "authIsTop" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "isSubTop") (EVar "p"))) (arm PWild () (EVar "False"))))
(DTypeSig true "authVars" (TyFun (TyCon "Authority") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar")))))
(DFunDef false "authVars" ((PVar "a")) (EApp (EVar "M.values") (EApp (EApp (EVar "varsInto") (EVar "a")) (EVar "Tip"))))
(DTypeSig false "varsInto" (TyFun (TyCon "Authority") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "varsInto" ((PVar "a") (PVar "acc")) (EBlock (DoLet false false (PTuple PWild (PVar "tuples") (PVar "vars")) (EApp (EApp (EVar "collect") (EListLit (EVar "a"))) (EApp (EApp (EApp (EVar "Parts") (EListLit)) (EListLit)) (EVar "Tip")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "t")) (EMatch (EVar "t") (arm (PCon "AProduct" (PVar "axes")) () (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m2") (PVar "ax")) (EApp (EApp (EVar "varsInto") (EApp (EVar "snd") (EVar "ax"))) (EVar "m2")))) (EVar "m")) (EVar "axes"))) (arm PWild () (EVar "m"))))) (EApp (EApp (EVar "M.union") (EVar "vars")) (EVar "acc"))) (EVar "tuples")))))
(DTypeSig true "authHasVars" (TyFun (TyCon "Authority") (TyCon "Bool")))
(DFunDef false "authHasVars" ((PVar "a")) (EMatch (EApp (EVar "authVars") (EVar "a")) (arm (PList) () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig true "authSub" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "authSub" ((PVar "lo") (PVar "hi")) (EApp (EApp (EVar "authSubN") (EApp (EVar "authNorm") (EVar "lo"))) (EApp (EVar "authNorm") (EVar "hi"))))
(DTypeSig false "authSubN" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "authSubN" ((PCon "AJoin" (PList)) PWild) (EVar "True"))
(DFunDef false "authSubN" ((PCon "AConst" (PVar "c")) (PCon "AConst" (PVar "d"))) (EApp (EApp (EVar "dsub") (EVar "c")) (EVar "d")))
(DFunDef false "authSubN" (PWild (PCon "AConst" (PVar "d"))) (EIf (EApp (EVar "isSubTop") (EVar "d")) (EVar "True") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "authSubN" ((PCon "AJoin" (PVar "ms")) (PVar "hi")) (EApp (EApp (EVar "allSub") (EVar "ms")) (EVar "hi")))
(DFunDef false "authSubN" ((PCon "AProduct" (PVar "xs")) (PCon "AConst" (PCon "PProduct" (PVar "dx")))) (EApp (EApp (EVar "axesWithin") (EVar "xs")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "AConst") (EApp (EVar "snd") (EVar "a")))))) (EVar "dx"))))
(DFunDef false "authSubN" (PWild (PCon "AConst" PWild)) (EVar "False"))
(DFunDef false "authSubN" ((PCon "AConst" (PVar "c")) (PCon "AJoin" (PVar "ms"))) (EBinOp "||" (EApp (EApp (EVar "anySub") (EApp (EVar "AConst") (EVar "c"))) (EVar "ms")) (EApp (EApp (EVar "dsubAny") (EVar "c")) (EApp (EVar "constantsOf") (EVar "ms")))))
(DFunDef false "authSubN" ((PCon "AConst" (PCon "PProduct" (PVar "cx"))) (PCon "AProduct" (PVar "ys"))) (EApp (EApp (EVar "axesWithin") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EVar "fst") (EVar "a")) (EApp (EVar "AConst") (EApp (EVar "snd") (EVar "a")))))) (EVar "cx"))) (EVar "ys")))
(DFunDef false "authSubN" ((PCon "AProduct" (PVar "xs")) (PCon "AProduct" (PVar "ys"))) (EApp (EApp (EVar "axesWithin") (EVar "xs")) (EVar "ys")))
(DFunDef false "authSubN" ((PVar "lo") (PCon "AJoin" (PVar "ms"))) (EApp (EApp (EVar "anySub") (EVar "lo")) (EVar "ms")))
(DFunDef false "authSubN" ((PCon "AVar" (PVar "v")) (PCon "AVar" (PVar "w"))) (EBinOp "==" (EApp (EVar "authvarId") (EVar "v")) (EApp (EVar "authvarId") (EVar "w"))))
(DFunDef false "authSubN" (PWild PWild) (EVar "False"))
(DTypeSig false "axesWithin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyCon "Bool"))))
(DFunDef false "axesWithin" ((PVar "xs") (PVar "ys")) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "xs")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ys"))) (EApp (EApp (EVar "allList") (ELam ((PVar "y")) (EMatch (EApp (EApp (EVar "lookupTerm") (EApp (EVar "fst") (EVar "y"))) (EVar "xs")) (arm (PCon "Some" (PVar "x")) () (EBinOp "&&" (EBinOp "==" (EApp (EVar "domainKey") (EApp (EVar "authDomainTop") (EVar "x"))) (EApp (EVar "domainKey") (EApp (EVar "authDomainTop") (EApp (EVar "snd") (EVar "y"))))) (EApp (EApp (EVar "authSub") (EVar "x")) (EApp (EVar "snd") (EVar "y"))))) (arm (PCon "None") () (EVar "False"))))) (EVar "ys"))))
(DTypeSig false "lookupTerm" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyApp (TyCon "Option") (TyCon "Authority")))))
(DFunDef false "lookupTerm" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupTerm" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "t")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "k")) (EApp (EVar "Some") (EVar "t")) (EApp (EApp (EVar "lookupTerm") (EVar "name")) (EVar "rest"))))
(DTypeSig true "authSplit" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyApp (TyCon "List") (TyTuple (TyCon "Authority") (TyCon "Authority"))))))
(DFunDef false "authSplit" ((PVar "lo") (PVar "hi")) (EMatch (EApp (EVar "authNorm") (EVar "hi")) (arm (PCon "AProduct" (PVar "axes")) () (EBlock (DoLet false false (PVar "schema") (EApp (EVar "domainKey") (EApp (EVar "authDomainTop") (EApp (EVar "AProduct") (EVar "axes"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "projections") (EVar "schema")) (EVar "axes")) (EVar "lo")) (arm (PCon "Some" (PVar "parts")) () (EVar "parts")) (arm (PCon "None") () (EListLit (ETuple (EVar "lo") (EVar "hi")))))))) (arm PWild () (EListLit (ETuple (EVar "lo") (EVar "hi"))))))
(DTypeSig false "projections" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyFun (TyCon "Authority") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Authority") (TyCon "Authority"))))))))
(DFunDef false "projections" (PWild (PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "projections" ((PVar "schema") (PCons (PTuple (PVar "name") (PVar "t")) (PVar "rest")) (PVar "lo")) (EMatch (ETuple (EApp (EApp (EApp (EVar "projectAxis") (EVar "schema")) (EVar "name")) (EVar "lo")) (EApp (EApp (EApp (EVar "projections") (EVar "schema")) (EVar "rest")) (EVar "lo"))) (arm (PTuple (PCon "Some" (PVar "p")) (PCon "Some" (PVar "more"))) () (EApp (EVar "Some") (EBinOp "::" (ETuple (EVar "p") (EVar "t")) (EVar "more")))) (arm PWild () (EVar "None"))))
(DTypeSig false "projectAxis" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Authority") (TyApp (TyCon "Option") (TyCon "Authority"))))))
(DFunDef false "projectAxis" ((PVar "schema") (PVar "name") (PVar "lo")) (EMatch (EApp (EVar "authNorm") (EVar "lo")) (arm (PCon "AJoin" (PList)) () (EApp (EVar "Some") (EApp (EVar "AJoin") (EListLit)))) (arm (PCon "AConst" (PAs "p" (PCon "PProduct" (PVar "ax")))) () (EIf (EBinOp "==" (EApp (EVar "domainKey") (EVar "p")) (EVar "schema")) (EApp (EApp (EMethodRef "map") (EVar "AConst")) (EApp (EApp (EVar "lookupAxis") (EVar "name")) (EVar "ax"))) (EVar "None"))) (arm (PCon "AProduct" (PVar "axes")) () (EIf (EBinOp "==" (EApp (EVar "domainKey") (EApp (EVar "authDomainTop") (EApp (EVar "AProduct") (EVar "axes")))) (EVar "schema")) (EApp (EApp (EVar "lookupTerm") (EVar "name")) (EVar "axes")) (EVar "None"))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "m")) (EMatch (ETuple (EVar "acc") (EApp (EApp (EApp (EVar "projectAxis") (EVar "schema")) (EVar "name")) (EVar "m"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EApp (EVar "authJoin") (EVar "a")) (EVar "b")))) (arm PWild () (EVar "None"))))) (EApp (EVar "Some") (EApp (EVar "AJoin") (EListLit)))) (EVar "ms"))) (arm PWild () (EVar "None"))))
(DTypeSig false "constantsOf" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyApp (TyCon "List") (TyCon "Param"))))
(DFunDef false "constantsOf" ((PList)) (EListLit))
(DFunDef false "constantsOf" ((PCons (PCon "AConst" (PVar "p")) (PVar "ms"))) (EBinOp "::" (EVar "p") (EApp (EVar "constantsOf") (EVar "ms"))))
(DFunDef false "constantsOf" ((PCons PWild (PVar "ms"))) (EApp (EVar "constantsOf") (EVar "ms")))
(DTypeSig false "allSub" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "allSub" ((PList) PWild) (EVar "True"))
(DFunDef false "allSub" ((PCons (PVar "m") (PVar "ms")) (PVar "hi")) (EBinOp "&&" (EApp (EApp (EVar "authSubN") (EVar "m")) (EVar "hi")) (EApp (EApp (EVar "allSub") (EVar "ms")) (EVar "hi"))))
(DTypeSig false "anySub" (TyFun (TyCon "Authority") (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Bool"))))
(DFunDef false "anySub" (PWild (PList)) (EVar "False"))
(DFunDef false "anySub" ((PVar "lo") (PCons (PVar "m") (PVar "ms"))) (EBinOp "||" (EApp (EApp (EVar "authSubN") (EVar "lo")) (EVar "m")) (EApp (EApp (EVar "anySub") (EVar "lo")) (EVar "ms"))))
(DTypeSig true "renderAuthorityWith" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "renderAuthorityWith" ((PVar "name") (PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AJoin" (PList)) () (ELit (LString " {}"))) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "drender") (EVar "p"))) (arm (PCon "AVar" (PVar "cell")) () (EBinOp "++" (ELit (LString " ")) (EApp (EVar "name") (EVar "cell")))) (arm (PCon "AJoin" (PVar "ms")) () (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renderOperand") (EVar "name"))) (EVar "ms")))) (ELit (LString ")")))) (arm (PCon "AProduct" (PVar "axes")) () (EBinOp "++" (ELit (LString " ")) (EApp (EApp (EVar "renderTuple") (EVar "name")) (EVar "axes"))))))
(DTypeSig false "renderOperand" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "renderOperand" (PWild (PCon "AConst" (PVar "p"))) (EApp (EVar "trimLeft") (EApp (EVar "drender") (EVar "p"))))
(DFunDef false "renderOperand" ((PVar "name") (PCon "AVar" (PVar "cell"))) (EApp (EVar "name") (EVar "cell")))
(DFunDef false "renderOperand" ((PVar "name") (PCon "AProduct" (PVar "axes"))) (EApp (EApp (EVar "renderTuple") (EVar "name")) (EVar "axes")))
(DFunDef false "renderOperand" ((PVar "name") (PVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "name")) (EVar "a")))
(DTypeSig false "renderTuple" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Authority"))) (TyCon "String"))))
(DFunDef false "renderTuple" ((PVar "name") (PVar "axes")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "a")))) (ELit (LString "="))) (EApp (EMethodRef "display") (EApp (EApp (EVar "renderAxisTerm") (EVar "name")) (EApp (EVar "snd") (EVar "a"))))) (ELit (LString ""))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EApp (EVar "not") (EApp (EVar "authIsTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "axes")))))
(DTypeSig false "renderAxisTerm" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "renderAxisTerm" ((PVar "name") (PVar "t")) (EMatch (EApp (EVar "authNorm") (EVar "t")) (arm (PCon "AConst" (PVar "p")) () (EApp (EVar "renderAxisVal") (EVar "p"))) (arm (PCon "AVar" (PVar "cell")) () (EApp (EVar "name") (EVar "cell"))) (arm (PCon "AJoin" (PList)) () (ELit (LString "{}"))) (arm (PCon "AJoin" (PVar "ms")) () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renderAxisTerm") (EVar "name"))) (EVar "ms")))) (ELit (LString ")")))) (arm (PCon "AProduct" (PVar "axes")) () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "renderTuple") (EVar "name")) (EVar "axes"))) (ELit (LString ")"))))))
(DTypeSig true "authvarDefaultName" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")))
(DFunDef false "authvarDefaultName" ((PVar "cell")) (EMatch (EApp (EVar "authvarName") (EVar "cell")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (EBinOp "++" (ELit (LString "k")) (EApp (EVar "intToString") (EApp (EVar "authvarId") (EVar "cell")))))))
(DTypeSig true "renderAuthority" (TyFun (TyCon "Authority") (TyCon "String")))
(DFunDef false "renderAuthority" ((PVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "authvarDefaultName")) (EVar "a")))
(DData Public "GrantShape" () ((variant "GrantTop" (ConPos)) (variant "GrantBottom" (ConPos)) (variant "GrantParts" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar")))))) ())
(DTypeSig true "authGrantShape" (TyFun (TyCon "Authority") (TyCon "GrantShape")))
(DFunDef false "authGrantShape" ((PVar "a")) (EMatch (EApp (EVar "authNorm") (EVar "a")) (arm (PCon "AJoin" (PList)) () (EVar "GrantBottom")) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EApp (EApp (EVar "grantJoin") (EVar "ms")) (EListLit)) (EListLit))) (arm (PVar "other") () (EApp (EApp (EApp (EVar "grantJoin") (EListLit (EVar "other"))) (EListLit)) (EListLit)))))
(DTypeSig false "grantJoin" (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "GrantShape")))))
(DFunDef false "grantJoin" ((PList) (PVar "elems") (PVar "vars")) (EApp (EApp (EVar "GrantParts") (EApp (EVar "reverseL") (EVar "elems"))) (EApp (EVar "reverseL") (EVar "vars"))))
(DFunDef false "grantJoin" ((PCons (PCon "AConst" (PVar "p")) (PVar "rest")) (PVar "elems") (PVar "vars")) (EIf (EApp (EVar "isSubTop") (EVar "p")) (EVar "GrantTop") (EApp (EApp (EApp (EVar "grantJoin") (EVar "rest")) (EBinOp "++" (EApp (EVar "reverseL") (EApp (EVar "paramElements") (EVar "p"))) (EVar "elems"))) (EVar "vars"))))
(DFunDef false "grantJoin" ((PCons (PCon "AVar" (PVar "cell")) (PVar "rest")) (PVar "elems") (PVar "vars")) (EApp (EApp (EApp (EVar "grantJoin") (EVar "rest")) (EVar "elems")) (EBinOp "::" (EVar "cell") (EVar "vars"))))
(DFunDef false "grantJoin" (PWild PWild PWild) (EVar "GrantTop"))
(DTypeSig false "paramElements" (TyFun (TyCon "Param") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramElements" ((PCon "PPrefix" (PCon "Some" (PVar "s")))) (EListLit (EVar "s")))
(DFunDef false "paramElements" ((PCon "PSet" (PCon "Some" (PVar "xs")))) (EVar "xs"))
(DFunDef false "paramElements" ((PVar "p")) (EListLit (EApp (EVar "trimLeft") (EApp (EVar "drender") (EVar "p")))))
