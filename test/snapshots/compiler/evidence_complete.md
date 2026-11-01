# META
source_lines=248
stages=DESUGAR,MARK
# SOURCE
-- The completeness judgment over the solver's final evidence: does every
-- dispatch destination of a program name an instance or a given?
--
-- `types/typecheck.mdk` builds one `EvidenceRow` per evidence destination at the
-- graph-end drain, after the stampers have written their last route, and reports
-- each row this module calls a hole as `T-UNROUTED-DISPATCH` at the row's site.
-- Nothing here reads inference state: a row is plain data, so a reader can audit
-- the predicate below without knowing how the solver reached its answer.
--
-- The predicate.  A route names a head when it is an `RKey` whose key has no `|`
-- (a type head such as `RKey "m.Box"`, not an instance key `m::I|heads|`), or when
-- such an `RKey` occurs inside it (an `RKey`'s dictionary lists, an `RLocal`'s
-- dictionaries, an `RProj`'s base).  A route has an unrouted part when `RNone`
-- occurs strictly inside it, at those same positions.  Then a row is a hole of:
--
--   * `UnroutedMethod` -- a method occurrence whose interface word is non-empty
--     and whose dispatch route is `RNone`;
--   * `HeadTagRoute` -- any route of the row names a head;
--   * `UnroutedPrerequisite` -- a method occurrence's impl or method dictionary
--     list holds `RNone`, or any route of the row has an unrouted part;
--   * `UnroutedDictSlot` -- a dictionary application has `RNone` in a slot.
--
-- Everything else passes, and each of these is a legitimate final answer:
--   * an operator or arithmetic site whose route is `RNone` (the structural and
--     primitive paths take it);
--   * a dictionary application with no slots (`EvMany []`);
--   * an occurrence with an empty interface word (a standalone) routed `RLocal`
--     or `RNone`;
--   * `RDict`, `RDictFwd`, `RScalar`, an `RProj` of a dictionary, and an `RKey`
--     whose key is an instance key.
-- An engine arm that treats a value as a hole may consume only what this
-- predicate flags; a value it lets through must keep a defined meaning there.
--
-- Below the top.  The solver shares one sub-route between every path that reaches
-- it, so a walk of a row's routes can be exponential in their depth.  The judgment
-- therefore reads only a row's top-level routes and the words of their children,
-- and takes everything deeper from an `Inner` the solver noted while it built the
-- destination: whether an `RNone`, or an `RKey` naming a head, occurs below that
-- depth.  the sibling test derives the same summary by walking, for a row built by
-- hand.

import frontend.ast.{Route(..)}
import list.{drop, findIndex}
import string.{contains, split}
import support.util.{anyList, filterList, splitLast}

export data HoleKind =
  | UnroutedMethod
  | HeadTagRoute
  | UnroutedPrerequisite
  | UnroutedDictSlot
  deriving (Eq, Debug)

-- One evidence destination, as the drain left it.
public export data EvidenceRow =
  -- A method occurrence: method name, interface word (`""` for a standalone),
  -- dispatch route, the selected impl's `requires` dictionaries and the method's
  -- own `=>` dictionaries.
  | OccurrenceRow String String Route (List Route) (List Route)
  -- A dictionary application: the callee's name (`""` when the goal does not
  -- carry it), the slot-ordered interface names (possibly shorter than the
  -- slots), and the slot-ordered routes.
  | DictAppRow String (List String) (List Route)
  -- An operator or arithmetic site's route.
  | SiteRow Route

-- What lies below the depth `holeKindsWith` reads: an `RNone` occurs there, and an
-- `RKey` naming a head occurs there.  The solver may also count positions the
-- judgment reads itself, since those give the same kinds.
public export data Inner = Inner Bool Bool

export
innerNone : Inner
innerNone = Inner False False

export
innerOr : Inner -> Inner -> Inner
innerOr (Inner n1 h1) (Inner n2 h2) = Inner (n1 || n2) (h1 || h2)

-- What [r] contributes when it sits below a destination's top level.
export
innerOfRoute : Route -> Inner
innerOfRoute r = Inner (isUnrouted r) (wordNamesHead r)

-- Every hole kind [row] exhibits, in `HoleKind` declaration order; `[]` for a
-- complete row, with what lies below the children read from [inner].
holeKindsWith : Inner -> EvidenceRow -> List HoleKind
holeKindsWith (Inner below belowHead) (OccurrenceRow _ iface tag impls meths) =
  let dicts = impls ++ meths
  kindsWhere [
    (UnroutedMethod, iface /= "" && isUnrouted tag),
    (
      HeadTagRoute,
      shallowHead tag || anyList shallowHead dicts || belowHead,
    ),
    (
      UnroutedPrerequisite,
      shallowUnrouted tag
        || anyList (r => isUnrouted r || shallowUnrouted r) dicts
        || below,
    ),
  ]
holeKindsWith (Inner below belowHead) (DictAppRow _ _ routes) = kindsWhere [
  (HeadTagRoute, anyList shallowHead routes || belowHead),
  (UnroutedPrerequisite, anyList shallowUnrouted routes || below),
  (UnroutedDictSlot, anyList isUnrouted routes),
]
holeKindsWith (Inner below belowHead) (SiteRow r) = kindsWhere [
  (HeadTagRoute, shallowHead r || belowHead),
  (UnroutedPrerequisite, shallowUnrouted r || below),
]

-- The row's first hole kind and the diagnostic text for it, or `None` for a
-- complete row, with what lies below the children read from [inner].  One
-- diagnostic per row: its later kinds describe the same unselected instance.  The
-- text walks the row, and is built only for a hole.
export
rowHoleWith : Inner -> EvidenceRow -> Option (HoleKind, String)
rowHoleWith inner row = match holeKindsWith inner row
  [] => None
  k :: _ => Some (k, holeMessage row k)

-- The `T-UNROUTED-DISPATCH` text for [kind] at [row].
export
holeMessage : EvidenceRow -> HoleKind -> String
-- A kind a row's shape never gives takes that shape's prerequisite
-- text.
holeMessage (OccurrenceRow name iface _ _ _) UnroutedMethod =
  "no impl of `\{bareName "::" iface}` is selected for this use of `\{name}`; annotate the type it is used at"
-- The row does not carry the occurrence's receiver, so the text names no type: the
-- head a route names can be any position's, such as the result's.
holeMessage (OccurrenceRow name iface _ _ _) HeadTagRoute =
  "\{noImplFor iface} is selected for this use of `\{name}`: its dispatch names a type, not an impl"
holeMessage (OccurrenceRow name _ _ _ _) UnroutedPrerequisite =
  occurrencePrerequisite name
holeMessage (OccurrenceRow name _ _ _ _) UnroutedDictSlot =
  occurrencePrerequisite name
holeMessage (DictAppRow callee ifaces routes) HeadTagRoute =
  "\{theCall callee} passes the type `\{headOf routes}` where its \{slotIface ifaces routes namesHead} constraint needs an impl"
holeMessage (DictAppRow callee ifaces routes) UnroutedDictSlot =
  "\{theCall callee} is missing the dictionary for its \{slotIface ifaces routes isUnrouted} constraint: no impl or given was selected for it"
holeMessage (DictAppRow callee ifaces routes) UnroutedPrerequisite =
  dictAppPrerequisite callee ifaces routes
holeMessage (DictAppRow callee ifaces routes) UnroutedMethod =
  dictAppPrerequisite callee ifaces routes
holeMessage (SiteRow r) HeadTagRoute =
  "this operator's dispatch names the type `\{headOf [r]}`, not an impl"
holeMessage (SiteRow _) UnroutedPrerequisite = sitePrerequisite
holeMessage (SiteRow _) UnroutedMethod = sitePrerequisite
holeMessage (SiteRow _) UnroutedDictSlot = sitePrerequisite

occurrencePrerequisite : String -> String
occurrencePrerequisite name =
  "the impl selected for this use of `\{name}` needs a dictionary that no impl or given supplies"

dictAppPrerequisite : String -> List String -> List Route -> String
dictAppPrerequisite callee ifaces routes =
  "the impl passed for the \{slotIface ifaces routes hasUnroutedPart} constraint of \{theCall callee} needs a dictionary that no impl or given supplies"

sitePrerequisite : String
sitePrerequisite =
  "the impl selected for this operator needs a dictionary that no impl or given supplies"

kindsWhere : List (HoleKind, Bool) -> List HoleKind
kindsWhere cases = map fst (filterList snd cases)

isUnrouted : Route -> Bool
isUnrouted RNone = True
isUnrouted _ = False

isInstanceKey : String -> Bool
isInstanceKey key = contains "|" key

-- The routes directly inside [r]: an `RKey`'s dictionary lists, an `RLocal`'s
-- dictionaries, an `RProj`'s base.
routeChildren : Route -> List Route
routeChildren (RKey _ ds ms) = ds ++ ms
routeChildren (RLocal _ ds) = ds
routeChildren (RProj r _) = [r]
routeChildren _ = []

-- [r]'s own word names a head.
wordNamesHead : Route -> Bool
wordNamesHead (RKey key _ _) = not (isInstanceKey key)
wordNamesHead _ = False

-- [r]'s own word, or a child's, names a head.
shallowHead : Route -> Bool
shallowHead r = wordNamesHead r || anyList wordNamesHead (routeChildren r)

-- A child of [r] is `RNone`.
shallowUnrouted : Route -> Bool
shallowUnrouted r = anyList isUnrouted (routeChildren r)

namesHead : Route -> Bool
namesHead (RKey key ds ms) =
  not (isInstanceKey key) || anyList namesHead ds || anyList namesHead ms
namesHead (RLocal _ ds) = anyList namesHead ds
namesHead (RProj r _) = namesHead r
namesHead _ = False

hasUnroutedPart : Route -> Bool
hasUnroutedPart (RKey _ ds ms) = anyList unroutedWithin (ds ++ ms)
hasUnroutedPart (RLocal _ ds) = anyList unroutedWithin ds
hasUnroutedPart (RProj r _) = unroutedWithin r
hasUnroutedPart _ = False

-- [r] is `RNone` or has an unrouted part.
unroutedWithin : Route -> Bool
unroutedWithin r = isUnrouted r || hasUnroutedPart r

-- The first type head named anywhere in [routes], unqualified.
headOf : List Route -> String
headOf routes = match firstHead routes
  Some key => bareName "." key
  None => "?"

firstHead : List Route -> Option String
firstHead [] = None
firstHead ((RKey key ds ms) :: rest)
  | not (isInstanceKey key) = Some key
  | otherwise = firstHead (ds ++ ms ++ rest)
firstHead ((RLocal _ ds) :: rest) = firstHead (ds ++ rest)
firstHead ((RProj r _) :: rest) = firstHead (r :: rest)
firstHead (_ :: rest) = firstHead rest

-- The last [sep]-separated segment of [word]: the unqualified name.
bareName : String -> String -> String
bareName sep word = match splitLast (split sep word)
  Some (_, last) => last
  None => word

noImplFor : String -> String
noImplFor "" = "no impl"
noImplFor iface = "no impl of `\{bareName "::" iface}`"

theCall : String -> String
theCall "" = "this call"
theCall callee = "this call to `\{callee}`"

-- The interface of the first slot [bad] flags, as "`I`", or "a" when the
-- application does not name it.
slotIface : List String -> List Route -> (Route -> Bool) -> String
slotIface ifaces routes bad = match findIndex bad routes
  Some i => match drop i ifaces
    iface :: _ => "`\{iface}`"
    [] => "a"
  None => "a"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Route" true))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "findIndex" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "split" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "filterList" false) (mem "splitLast" false))))
(DData Abstract "HoleKind" () ((variant "UnroutedMethod" (ConPos)) (variant "HeadTagRoute" (ConPos)) (variant "UnroutedPrerequisite" (ConPos)) (variant "UnroutedDictSlot" (ConPos))) ())
(DImpl true "Eq" ((TyCon "HoleKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "UnroutedMethod") (PCon "UnroutedMethod")) () (EVar "True")) (arm (PTuple (PCon "HeadTagRoute") (PCon "HeadTagRoute")) () (EVar "True")) (arm (PTuple (PCon "UnroutedPrerequisite") (PCon "UnroutedPrerequisite")) () (EVar "True")) (arm (PTuple (PCon "UnroutedDictSlot") (PCon "UnroutedDictSlot")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "HoleKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "UnroutedMethod") () (ELit (LString "UnroutedMethod"))) (arm (PCon "HeadTagRoute") () (ELit (LString "HeadTagRoute"))) (arm (PCon "UnroutedPrerequisite") () (ELit (LString "UnroutedPrerequisite"))) (arm (PCon "UnroutedDictSlot") () (ELit (LString "UnroutedDictSlot")))))))
(DData Public "EvidenceRow" () ((variant "OccurrenceRow" (ConPos (TyCon "String") (TyCon "String") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route")))) (variant "DictAppRow" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Route")))) (variant "SiteRow" (ConPos (TyCon "Route")))) ())
(DData Public "Inner" () ((variant "Inner" (ConPos (TyCon "Bool") (TyCon "Bool")))) ())
(DTypeSig true "innerNone" (TyCon "Inner"))
(DFunDef false "innerNone" () (EApp (EApp (EVar "Inner") (EVar "False")) (EVar "False")))
(DTypeSig true "innerOr" (TyFun (TyCon "Inner") (TyFun (TyCon "Inner") (TyCon "Inner"))))
(DFunDef false "innerOr" ((PCon "Inner" (PVar "n1") (PVar "h1")) (PCon "Inner" (PVar "n2") (PVar "h2"))) (EApp (EApp (EVar "Inner") (EBinOp "||" (EVar "n1") (EVar "n2"))) (EBinOp "||" (EVar "h1") (EVar "h2"))))
(DTypeSig true "innerOfRoute" (TyFun (TyCon "Route") (TyCon "Inner")))
(DFunDef false "innerOfRoute" ((PVar "r")) (EApp (EApp (EVar "Inner") (EApp (EVar "isUnrouted") (EVar "r"))) (EApp (EVar "wordNamesHead") (EVar "r"))))
(DTypeSig false "holeKindsWith" (TyFun (TyCon "Inner") (TyFun (TyCon "EvidenceRow") (TyApp (TyCon "List") (TyCon "HoleKind")))))
(DFunDef false "holeKindsWith" ((PCon "Inner" (PVar "below") (PVar "belowHead")) (PCon "OccurrenceRow" PWild (PVar "iface") (PVar "tag") (PVar "impls") (PVar "meths"))) (EBlock (DoLet false false (PVar "dicts") (EBinOp "++" (EVar "impls") (EVar "meths"))) (DoExpr (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "UnroutedMethod") (EBinOp "&&" (EBinOp "/=" (EVar "iface") (ELit (LString ""))) (EApp (EVar "isUnrouted") (EVar "tag")))) (ETuple (EVar "HeadTagRoute") (EBinOp "||" (EBinOp "||" (EApp (EVar "shallowHead") (EVar "tag")) (EApp (EApp (EVar "anyList") (EVar "shallowHead")) (EVar "dicts"))) (EVar "belowHead"))) (ETuple (EVar "UnroutedPrerequisite") (EBinOp "||" (EBinOp "||" (EApp (EVar "shallowUnrouted") (EVar "tag")) (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "shallowUnrouted") (EVar "r"))))) (EVar "dicts"))) (EVar "below"))))))))
(DFunDef false "holeKindsWith" ((PCon "Inner" (PVar "below") (PVar "belowHead")) (PCon "DictAppRow" PWild PWild (PVar "routes"))) (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "HeadTagRoute") (EBinOp "||" (EApp (EApp (EVar "anyList") (EVar "shallowHead")) (EVar "routes")) (EVar "belowHead"))) (ETuple (EVar "UnroutedPrerequisite") (EBinOp "||" (EApp (EApp (EVar "anyList") (EVar "shallowUnrouted")) (EVar "routes")) (EVar "below"))) (ETuple (EVar "UnroutedDictSlot") (EApp (EApp (EVar "anyList") (EVar "isUnrouted")) (EVar "routes"))))))
(DFunDef false "holeKindsWith" ((PCon "Inner" (PVar "below") (PVar "belowHead")) (PCon "SiteRow" (PVar "r"))) (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "HeadTagRoute") (EBinOp "||" (EApp (EVar "shallowHead") (EVar "r")) (EVar "belowHead"))) (ETuple (EVar "UnroutedPrerequisite") (EBinOp "||" (EApp (EVar "shallowUnrouted") (EVar "r")) (EVar "below"))))))
(DTypeSig true "rowHoleWith" (TyFun (TyCon "Inner") (TyFun (TyCon "EvidenceRow") (TyApp (TyCon "Option") (TyTuple (TyCon "HoleKind") (TyCon "String"))))))
(DFunDef false "rowHoleWith" ((PVar "inner") (PVar "row")) (EMatch (EApp (EApp (EVar "holeKindsWith") (EVar "inner")) (EVar "row")) (arm (PList) () (EVar "None")) (arm (PCons (PVar "k") PWild) () (EApp (EVar "Some") (ETuple (EVar "k") (EApp (EApp (EVar "holeMessage") (EVar "row")) (EVar "k")))))))
(DTypeSig true "holeMessage" (TyFun (TyCon "EvidenceRow") (TyFun (TyCon "HoleKind") (TyCon "String"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") (PVar "iface") PWild PWild PWild) (PCon "UnroutedMethod")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of `")) (EApp (EVar "display") (EApp (EApp (EVar "bareName") (ELit (LString "::"))) (EVar "iface")))) (ELit (LString "` is selected for this use of `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`; annotate the type it is used at"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") (PVar "iface") PWild PWild PWild) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "noImplFor") (EVar "iface")))) (ELit (LString " is selected for this use of `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`: its dispatch names a type, not an impl"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") PWild PWild PWild PWild) (PCon "UnroutedPrerequisite")) (EApp (EVar "occurrencePrerequisite") (EVar "name")))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") PWild PWild PWild PWild) (PCon "UnroutedDictSlot")) (EApp (EVar "occurrencePrerequisite") (EVar "name")))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " passes the type `"))) (EApp (EVar "display") (EApp (EVar "headOf") (EVar "routes")))) (ELit (LString "` where its "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "namesHead")))) (ELit (LString " constraint needs an impl"))))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "UnroutedDictSlot")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " is missing the dictionary for its "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "isUnrouted")))) (ELit (LString " constraint: no impl or given was selected for it"))))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "UnroutedPrerequisite")) (EApp (EApp (EApp (EVar "dictAppPrerequisite") (EVar "callee")) (EVar "ifaces")) (EVar "routes")))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "UnroutedMethod")) (EApp (EApp (EApp (EVar "dictAppPrerequisite") (EVar "callee")) (EVar "ifaces")) (EVar "routes")))
(DFunDef false "holeMessage" ((PCon "SiteRow" (PVar "r")) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (ELit (LString "this operator's dispatch names the type `")) (EApp (EVar "display") (EApp (EVar "headOf") (EListLit (EVar "r"))))) (ELit (LString "`, not an impl"))))
(DFunDef false "holeMessage" ((PCon "SiteRow" PWild) (PCon "UnroutedPrerequisite")) (EVar "sitePrerequisite"))
(DFunDef false "holeMessage" ((PCon "SiteRow" PWild) (PCon "UnroutedMethod")) (EVar "sitePrerequisite"))
(DFunDef false "holeMessage" ((PCon "SiteRow" PWild) (PCon "UnroutedDictSlot")) (EVar "sitePrerequisite"))
(DTypeSig false "occurrencePrerequisite" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "occurrencePrerequisite" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "the impl selected for this use of `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` needs a dictionary that no impl or given supplies"))))
(DTypeSig false "dictAppPrerequisite" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "String")))))
(DFunDef false "dictAppPrerequisite" ((PVar "callee") (PVar "ifaces") (PVar "routes")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the impl passed for the ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "hasUnroutedPart")))) (ELit (LString " constraint of "))) (EApp (EVar "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " needs a dictionary that no impl or given supplies"))))
(DTypeSig false "sitePrerequisite" (TyCon "String"))
(DFunDef false "sitePrerequisite" () (ELit (LString "the impl selected for this operator needs a dictionary that no impl or given supplies")))
(DTypeSig false "kindsWhere" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "HoleKind") (TyCon "Bool"))) (TyApp (TyCon "List") (TyCon "HoleKind"))))
(DFunDef false "kindsWhere" ((PVar "cases")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (EVar "snd")) (EVar "cases"))))
(DTypeSig false "isUnrouted" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "isUnrouted" ((PCon "RNone")) (EVar "True"))
(DFunDef false "isUnrouted" (PWild) (EVar "False"))
(DTypeSig false "isInstanceKey" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isInstanceKey" ((PVar "key")) (EApp (EApp (EVar "contains") (ELit (LString "|"))) (EVar "key")))
(DTypeSig false "routeChildren" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "routeChildren" ((PCon "RKey" PWild (PVar "ds") (PVar "ms"))) (EBinOp "++" (EVar "ds") (EVar "ms")))
(DFunDef false "routeChildren" ((PCon "RLocal" PWild (PVar "ds"))) (EVar "ds"))
(DFunDef false "routeChildren" ((PCon "RProj" (PVar "r") PWild)) (EListLit (EVar "r")))
(DFunDef false "routeChildren" (PWild) (EListLit))
(DTypeSig false "wordNamesHead" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "wordNamesHead" ((PCon "RKey" (PVar "key") PWild PWild)) (EApp (EVar "not") (EApp (EVar "isInstanceKey") (EVar "key"))))
(DFunDef false "wordNamesHead" (PWild) (EVar "False"))
(DTypeSig false "shallowHead" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "shallowHead" ((PVar "r")) (EBinOp "||" (EApp (EVar "wordNamesHead") (EVar "r")) (EApp (EApp (EVar "anyList") (EVar "wordNamesHead")) (EApp (EVar "routeChildren") (EVar "r")))))
(DTypeSig false "shallowUnrouted" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "shallowUnrouted" ((PVar "r")) (EApp (EApp (EVar "anyList") (EVar "isUnrouted")) (EApp (EVar "routeChildren") (EVar "r"))))
(DTypeSig false "namesHead" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "namesHead" ((PCon "RKey" (PVar "key") (PVar "ds") (PVar "ms"))) (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isInstanceKey") (EVar "key"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ds"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ms"))))
(DFunDef false "namesHead" ((PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ds")))
(DFunDef false "namesHead" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "namesHead") (EVar "r")))
(DFunDef false "namesHead" (PWild) (EVar "False"))
(DTypeSig false "hasUnroutedPart" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "hasUnroutedPart" ((PCon "RKey" PWild (PVar "ds") (PVar "ms"))) (EApp (EApp (EVar "anyList") (EVar "unroutedWithin")) (EBinOp "++" (EVar "ds") (EVar "ms"))))
(DFunDef false "hasUnroutedPart" ((PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EVar "anyList") (EVar "unroutedWithin")) (EVar "ds")))
(DFunDef false "hasUnroutedPart" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "unroutedWithin") (EVar "r")))
(DFunDef false "hasUnroutedPart" (PWild) (EVar "False"))
(DTypeSig false "unroutedWithin" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "unroutedWithin" ((PVar "r")) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "hasUnroutedPart") (EVar "r"))))
(DTypeSig false "headOf" (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "String")))
(DFunDef false "headOf" ((PVar "routes")) (EMatch (EApp (EVar "firstHead") (EVar "routes")) (arm (PCon "Some" (PVar "key")) () (EApp (EApp (EVar "bareName") (ELit (LString "."))) (EVar "key"))) (arm (PCon "None") () (ELit (LString "?")))))
(DTypeSig false "firstHead" (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "firstHead" ((PList)) (EVar "None"))
(DFunDef false "firstHead" ((PCons (PCon "RKey" (PVar "key") (PVar "ds") (PVar "ms")) (PVar "rest"))) (EIf (EApp (EVar "not") (EApp (EVar "isInstanceKey") (EVar "key"))) (EApp (EVar "Some") (EVar "key")) (EIf (EVar "otherwise") (EApp (EVar "firstHead") (EBinOp "++" (EBinOp "++" (EVar "ds") (EVar "ms")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "firstHead" ((PCons (PCon "RLocal" PWild (PVar "ds")) (PVar "rest"))) (EApp (EVar "firstHead") (EBinOp "++" (EVar "ds") (EVar "rest"))))
(DFunDef false "firstHead" ((PCons (PCon "RProj" (PVar "r") PWild) (PVar "rest"))) (EApp (EVar "firstHead") (EBinOp "::" (EVar "r") (EVar "rest"))))
(DFunDef false "firstHead" ((PCons PWild (PVar "rest"))) (EApp (EVar "firstHead") (EVar "rest")))
(DTypeSig false "bareName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "bareName" ((PVar "sep") (PVar "word")) (EMatch (EApp (EVar "splitLast") (EApp (EApp (EVar "split") (EVar "sep")) (EVar "word"))) (arm (PCon "Some" (PTuple PWild (PVar "last"))) () (EVar "last")) (arm (PCon "None") () (EVar "word"))))
(DTypeSig false "noImplFor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "noImplFor" ((PLit (LString ""))) (ELit (LString "no impl")))
(DFunDef false "noImplFor" ((PVar "iface")) (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of `")) (EApp (EVar "display") (EApp (EApp (EVar "bareName") (ELit (LString "::"))) (EVar "iface")))) (ELit (LString "`"))))
(DTypeSig false "theCall" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "theCall" ((PLit (LString ""))) (ELit (LString "this call")))
(DFunDef false "theCall" ((PVar "callee")) (EBinOp "++" (EBinOp "++" (ELit (LString "this call to `")) (EApp (EVar "display") (EVar "callee"))) (ELit (LString "`"))))
(DTypeSig false "slotIface" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyFun (TyFun (TyCon "Route") (TyCon "Bool")) (TyCon "String")))))
(DFunDef false "slotIface" ((PVar "ifaces") (PVar "routes") (PVar "bad")) (EMatch (EApp (EApp (EVar "findIndex") (EVar "bad")) (EVar "routes")) (arm (PCon "Some" (PVar "i")) () (EMatch (EApp (EApp (EVar "drop") (EVar "i")) (EVar "ifaces")) (arm (PCons (PVar "iface") PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "`")))) (arm (PList) () (ELit (LString "a"))))) (arm (PCon "None") () (ELit (LString "a")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Route" true))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "findIndex" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "split" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "filterList" false) (mem "splitLast" false))))
(DData Abstract "HoleKind" () ((variant "UnroutedMethod" (ConPos)) (variant "HeadTagRoute" (ConPos)) (variant "UnroutedPrerequisite" (ConPos)) (variant "UnroutedDictSlot" (ConPos))) ())
(DImpl true "Eq" ((TyCon "HoleKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "UnroutedMethod") (PCon "UnroutedMethod")) () (EVar "True")) (arm (PTuple (PCon "HeadTagRoute") (PCon "HeadTagRoute")) () (EVar "True")) (arm (PTuple (PCon "UnroutedPrerequisite") (PCon "UnroutedPrerequisite")) () (EVar "True")) (arm (PTuple (PCon "UnroutedDictSlot") (PCon "UnroutedDictSlot")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "HoleKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "UnroutedMethod") () (ELit (LString "UnroutedMethod"))) (arm (PCon "HeadTagRoute") () (ELit (LString "HeadTagRoute"))) (arm (PCon "UnroutedPrerequisite") () (ELit (LString "UnroutedPrerequisite"))) (arm (PCon "UnroutedDictSlot") () (ELit (LString "UnroutedDictSlot")))))))
(DData Public "EvidenceRow" () ((variant "OccurrenceRow" (ConPos (TyCon "String") (TyCon "String") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route")))) (variant "DictAppRow" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Route")))) (variant "SiteRow" (ConPos (TyCon "Route")))) ())
(DData Public "Inner" () ((variant "Inner" (ConPos (TyCon "Bool") (TyCon "Bool")))) ())
(DTypeSig true "innerNone" (TyCon "Inner"))
(DFunDef false "innerNone" () (EApp (EApp (EVar "Inner") (EVar "False")) (EVar "False")))
(DTypeSig true "innerOr" (TyFun (TyCon "Inner") (TyFun (TyCon "Inner") (TyCon "Inner"))))
(DFunDef false "innerOr" ((PCon "Inner" (PVar "n1") (PVar "h1")) (PCon "Inner" (PVar "n2") (PVar "h2"))) (EApp (EApp (EVar "Inner") (EBinOp "||" (EVar "n1") (EVar "n2"))) (EBinOp "||" (EVar "h1") (EVar "h2"))))
(DTypeSig true "innerOfRoute" (TyFun (TyCon "Route") (TyCon "Inner")))
(DFunDef false "innerOfRoute" ((PVar "r")) (EApp (EApp (EVar "Inner") (EApp (EVar "isUnrouted") (EVar "r"))) (EApp (EVar "wordNamesHead") (EVar "r"))))
(DTypeSig false "holeKindsWith" (TyFun (TyCon "Inner") (TyFun (TyCon "EvidenceRow") (TyApp (TyCon "List") (TyCon "HoleKind")))))
(DFunDef false "holeKindsWith" ((PCon "Inner" (PVar "below") (PVar "belowHead")) (PCon "OccurrenceRow" PWild (PVar "iface") (PVar "tag") (PVar "impls") (PVar "meths"))) (EBlock (DoLet false false (PVar "dicts") (EBinOp "++" (EVar "impls") (EVar "meths"))) (DoExpr (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "UnroutedMethod") (EBinOp "&&" (EBinOp "/=" (EVar "iface") (ELit (LString ""))) (EApp (EVar "isUnrouted") (EVar "tag")))) (ETuple (EVar "HeadTagRoute") (EBinOp "||" (EBinOp "||" (EApp (EVar "shallowHead") (EVar "tag")) (EApp (EApp (EVar "anyList") (EVar "shallowHead")) (EVar "dicts"))) (EVar "belowHead"))) (ETuple (EVar "UnroutedPrerequisite") (EBinOp "||" (EBinOp "||" (EApp (EVar "shallowUnrouted") (EVar "tag")) (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "shallowUnrouted") (EVar "r"))))) (EVar "dicts"))) (EVar "below"))))))))
(DFunDef false "holeKindsWith" ((PCon "Inner" (PVar "below") (PVar "belowHead")) (PCon "DictAppRow" PWild PWild (PVar "routes"))) (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "HeadTagRoute") (EBinOp "||" (EApp (EApp (EVar "anyList") (EVar "shallowHead")) (EVar "routes")) (EVar "belowHead"))) (ETuple (EVar "UnroutedPrerequisite") (EBinOp "||" (EApp (EApp (EVar "anyList") (EVar "shallowUnrouted")) (EVar "routes")) (EVar "below"))) (ETuple (EVar "UnroutedDictSlot") (EApp (EApp (EVar "anyList") (EVar "isUnrouted")) (EVar "routes"))))))
(DFunDef false "holeKindsWith" ((PCon "Inner" (PVar "below") (PVar "belowHead")) (PCon "SiteRow" (PVar "r"))) (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "HeadTagRoute") (EBinOp "||" (EApp (EVar "shallowHead") (EVar "r")) (EVar "belowHead"))) (ETuple (EVar "UnroutedPrerequisite") (EBinOp "||" (EApp (EVar "shallowUnrouted") (EVar "r")) (EVar "below"))))))
(DTypeSig true "rowHoleWith" (TyFun (TyCon "Inner") (TyFun (TyCon "EvidenceRow") (TyApp (TyCon "Option") (TyTuple (TyCon "HoleKind") (TyCon "String"))))))
(DFunDef false "rowHoleWith" ((PVar "inner") (PVar "row")) (EMatch (EApp (EApp (EVar "holeKindsWith") (EVar "inner")) (EVar "row")) (arm (PList) () (EVar "None")) (arm (PCons (PVar "k") PWild) () (EApp (EVar "Some") (ETuple (EVar "k") (EApp (EApp (EVar "holeMessage") (EVar "row")) (EVar "k")))))))
(DTypeSig true "holeMessage" (TyFun (TyCon "EvidenceRow") (TyFun (TyCon "HoleKind") (TyCon "String"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") (PVar "iface") PWild PWild PWild) (PCon "UnroutedMethod")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "bareName") (ELit (LString "::"))) (EVar "iface")))) (ELit (LString "` is selected for this use of `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`; annotate the type it is used at"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") (PVar "iface") PWild PWild PWild) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "noImplFor") (EVar "iface")))) (ELit (LString " is selected for this use of `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`: its dispatch names a type, not an impl"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") PWild PWild PWild PWild) (PCon "UnroutedPrerequisite")) (EApp (EVar "occurrencePrerequisite") (EVar "name")))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") PWild PWild PWild PWild) (PCon "UnroutedDictSlot")) (EApp (EVar "occurrencePrerequisite") (EVar "name")))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " passes the type `"))) (EApp (EMethodRef "display") (EApp (EVar "headOf") (EVar "routes")))) (ELit (LString "` where its "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "namesHead")))) (ELit (LString " constraint needs an impl"))))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "UnroutedDictSlot")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " is missing the dictionary for its "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "isUnrouted")))) (ELit (LString " constraint: no impl or given was selected for it"))))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "UnroutedPrerequisite")) (EApp (EApp (EApp (EVar "dictAppPrerequisite") (EVar "callee")) (EVar "ifaces")) (EVar "routes")))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "UnroutedMethod")) (EApp (EApp (EApp (EVar "dictAppPrerequisite") (EVar "callee")) (EVar "ifaces")) (EVar "routes")))
(DFunDef false "holeMessage" ((PCon "SiteRow" (PVar "r")) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (ELit (LString "this operator's dispatch names the type `")) (EApp (EMethodRef "display") (EApp (EVar "headOf") (EListLit (EVar "r"))))) (ELit (LString "`, not an impl"))))
(DFunDef false "holeMessage" ((PCon "SiteRow" PWild) (PCon "UnroutedPrerequisite")) (EVar "sitePrerequisite"))
(DFunDef false "holeMessage" ((PCon "SiteRow" PWild) (PCon "UnroutedMethod")) (EVar "sitePrerequisite"))
(DFunDef false "holeMessage" ((PCon "SiteRow" PWild) (PCon "UnroutedDictSlot")) (EVar "sitePrerequisite"))
(DTypeSig false "occurrencePrerequisite" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "occurrencePrerequisite" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "the impl selected for this use of `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` needs a dictionary that no impl or given supplies"))))
(DTypeSig false "dictAppPrerequisite" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "String")))))
(DFunDef false "dictAppPrerequisite" ((PVar "callee") (PVar "ifaces") (PVar "routes")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the impl passed for the ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "hasUnroutedPart")))) (ELit (LString " constraint of "))) (EApp (EMethodRef "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " needs a dictionary that no impl or given supplies"))))
(DTypeSig false "sitePrerequisite" (TyCon "String"))
(DFunDef false "sitePrerequisite" () (ELit (LString "the impl selected for this operator needs a dictionary that no impl or given supplies")))
(DTypeSig false "kindsWhere" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "HoleKind") (TyCon "Bool"))) (TyApp (TyCon "List") (TyCon "HoleKind"))))
(DFunDef false "kindsWhere" ((PVar "cases")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (EVar "snd")) (EVar "cases"))))
(DTypeSig false "isUnrouted" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "isUnrouted" ((PCon "RNone")) (EVar "True"))
(DFunDef false "isUnrouted" (PWild) (EVar "False"))
(DTypeSig false "isInstanceKey" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isInstanceKey" ((PVar "key")) (EApp (EApp (EVar "contains") (ELit (LString "|"))) (EVar "key")))
(DTypeSig false "routeChildren" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "routeChildren" ((PCon "RKey" PWild (PVar "ds") (PVar "ms"))) (EBinOp "++" (EVar "ds") (EVar "ms")))
(DFunDef false "routeChildren" ((PCon "RLocal" PWild (PVar "ds"))) (EVar "ds"))
(DFunDef false "routeChildren" ((PCon "RProj" (PVar "r") PWild)) (EListLit (EVar "r")))
(DFunDef false "routeChildren" (PWild) (EListLit))
(DTypeSig false "wordNamesHead" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "wordNamesHead" ((PCon "RKey" (PVar "key") PWild PWild)) (EApp (EVar "not") (EApp (EVar "isInstanceKey") (EVar "key"))))
(DFunDef false "wordNamesHead" (PWild) (EVar "False"))
(DTypeSig false "shallowHead" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "shallowHead" ((PVar "r")) (EBinOp "||" (EApp (EVar "wordNamesHead") (EVar "r")) (EApp (EApp (EVar "anyList") (EVar "wordNamesHead")) (EApp (EVar "routeChildren") (EVar "r")))))
(DTypeSig false "shallowUnrouted" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "shallowUnrouted" ((PVar "r")) (EApp (EApp (EVar "anyList") (EVar "isUnrouted")) (EApp (EVar "routeChildren") (EVar "r"))))
(DTypeSig false "namesHead" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "namesHead" ((PCon "RKey" (PVar "key") (PVar "ds") (PVar "ms"))) (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isInstanceKey") (EVar "key"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ds"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ms"))))
(DFunDef false "namesHead" ((PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ds")))
(DFunDef false "namesHead" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "namesHead") (EVar "r")))
(DFunDef false "namesHead" (PWild) (EVar "False"))
(DTypeSig false "hasUnroutedPart" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "hasUnroutedPart" ((PCon "RKey" PWild (PVar "ds") (PVar "ms"))) (EApp (EApp (EVar "anyList") (EVar "unroutedWithin")) (EBinOp "++" (EVar "ds") (EVar "ms"))))
(DFunDef false "hasUnroutedPart" ((PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EVar "anyList") (EVar "unroutedWithin")) (EVar "ds")))
(DFunDef false "hasUnroutedPart" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "unroutedWithin") (EVar "r")))
(DFunDef false "hasUnroutedPart" (PWild) (EVar "False"))
(DTypeSig false "unroutedWithin" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "unroutedWithin" ((PVar "r")) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "hasUnroutedPart") (EVar "r"))))
(DTypeSig false "headOf" (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "String")))
(DFunDef false "headOf" ((PVar "routes")) (EMatch (EApp (EVar "firstHead") (EVar "routes")) (arm (PCon "Some" (PVar "key")) () (EApp (EApp (EVar "bareName") (ELit (LString "."))) (EVar "key"))) (arm (PCon "None") () (ELit (LString "?")))))
(DTypeSig false "firstHead" (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "firstHead" ((PList)) (EVar "None"))
(DFunDef false "firstHead" ((PCons (PCon "RKey" (PVar "key") (PVar "ds") (PVar "ms")) (PVar "rest"))) (EIf (EApp (EVar "not") (EApp (EVar "isInstanceKey") (EVar "key"))) (EApp (EVar "Some") (EVar "key")) (EIf (EVar "otherwise") (EApp (EVar "firstHead") (EBinOp "++" (EBinOp "++" (EVar "ds") (EVar "ms")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "firstHead" ((PCons (PCon "RLocal" PWild (PVar "ds")) (PVar "rest"))) (EApp (EVar "firstHead") (EBinOp "++" (EVar "ds") (EVar "rest"))))
(DFunDef false "firstHead" ((PCons (PCon "RProj" (PVar "r") PWild) (PVar "rest"))) (EApp (EVar "firstHead") (EBinOp "::" (EVar "r") (EVar "rest"))))
(DFunDef false "firstHead" ((PCons PWild (PVar "rest"))) (EApp (EVar "firstHead") (EVar "rest")))
(DTypeSig false "bareName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "bareName" ((PVar "sep") (PVar "word")) (EMatch (EApp (EVar "splitLast") (EApp (EApp (EVar "split") (EVar "sep")) (EVar "word"))) (arm (PCon "Some" (PTuple PWild (PVar "last"))) () (EVar "last")) (arm (PCon "None") () (EVar "word"))))
(DTypeSig false "noImplFor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "noImplFor" ((PLit (LString ""))) (ELit (LString "no impl")))
(DFunDef false "noImplFor" ((PVar "iface")) (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "bareName") (ELit (LString "::"))) (EVar "iface")))) (ELit (LString "`"))))
(DTypeSig false "theCall" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "theCall" ((PLit (LString ""))) (ELit (LString "this call")))
(DFunDef false "theCall" ((PVar "callee")) (EBinOp "++" (EBinOp "++" (ELit (LString "this call to `")) (EApp (EMethodRef "display") (EVar "callee"))) (ELit (LString "`"))))
(DTypeSig false "slotIface" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyFun (TyFun (TyCon "Route") (TyCon "Bool")) (TyCon "String")))))
(DFunDef false "slotIface" ((PVar "ifaces") (PVar "routes") (PVar "bad")) (EMatch (EApp (EApp (EVar "findIndex") (EVar "bad")) (EVar "routes")) (arm (PCon "Some" (PVar "i")) () (EMatch (EApp (EApp (EVar "drop") (EVar "i")) (EVar "ifaces")) (arm (PCons (PVar "iface") PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "`")))) (arm (PList) () (ELit (LString "a"))))) (arm (PCon "None") () (ELit (LString "a")))))
