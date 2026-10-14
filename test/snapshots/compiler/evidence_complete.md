# META
source_lines=176
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

import frontend.ast.{Route(..)}
import list.{drop, findIndex}
import string.{contains, split}
import support.util.{anyList, filterList, splitLast}

public export data HoleKind =
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

-- Every hole kind [row] exhibits, in `HoleKind` declaration order; `[]` for a
-- complete row.
export
holeKindsOf : EvidenceRow -> List HoleKind
holeKindsOf (OccurrenceRow _ iface tag impls meths) =
  let dicts = impls ++ meths
  kindsWhere [
    (UnroutedMethod, iface /= "" && isUnrouted tag),
    (HeadTagRoute, namesHead tag || anyList namesHead dicts),
    (
      UnroutedPrerequisite,
      hasUnroutedPart tag
        || anyList (r => isUnrouted r || hasUnroutedPart r) dicts,
    ),
  ]
holeKindsOf (DictAppRow _ _ routes) = kindsWhere [
  (HeadTagRoute, anyList namesHead routes),
  (UnroutedPrerequisite, anyList hasUnroutedPart routes),
  (UnroutedDictSlot, anyList isUnrouted routes),
]
holeKindsOf (SiteRow r) = kindsWhere [
  (HeadTagRoute, namesHead r),
  (UnroutedPrerequisite, hasUnroutedPart r),
]

-- The row's first hole kind and the diagnostic text for it, or `None` for a
-- complete row.  One diagnostic per row: its later kinds describe the same
-- unselected instance.
export
rowHole : EvidenceRow -> Option (HoleKind, String)
rowHole row = match holeKindsOf row
  [] => None
  k :: _ => Some (k, holeMessage row k)

-- The `T-UNROUTED-DISPATCH` text for [kind] at [row].
export
holeMessage : EvidenceRow -> HoleKind -> String
holeMessage (OccurrenceRow name iface _ _ _) UnroutedMethod =
  "no impl of `\{bareName "::" iface}` is selected for this use of `\{name}`; annotate the type it is used at"
-- The row does not carry the occurrence's receiver, so the text names no type: the
-- head a route names can be any position's, such as the result's.
holeMessage (OccurrenceRow name iface _ _ _) HeadTagRoute =
  "\{noImplFor iface} is selected for this use of `\{name}`: its dispatch names a type, not an impl"
holeMessage (OccurrenceRow name _ _ _ _) _ =
  "the impl selected for this use of `\{name}` needs a dictionary that no impl or given supplies"
holeMessage (DictAppRow callee ifaces routes) HeadTagRoute =
  "\{theCall callee} passes the type `\{headOf routes}` where its \{slotIface ifaces routes namesHead} constraint needs an impl"
holeMessage (DictAppRow callee ifaces routes) UnroutedDictSlot =
  "\{theCall callee} is missing the dictionary for its \{slotIface ifaces routes isUnrouted} constraint: no impl or given was selected for it"
holeMessage (DictAppRow callee ifaces routes) _ =
  "the impl passed for the \{slotIface ifaces routes hasUnroutedPart} constraint of \{theCall callee} needs a dictionary that no impl or given supplies"
holeMessage (SiteRow r) HeadTagRoute =
  "this operator's dispatch names the type `\{headOf [r]}`, not an impl"
holeMessage (SiteRow _) _ =
  "the impl selected for this operator needs a dictionary that no impl or given supplies"

kindsWhere : List (HoleKind, Bool) -> List HoleKind
kindsWhere cases = map fst (filterList snd cases)

isUnrouted : Route -> Bool
isUnrouted RNone = True
isUnrouted _ = False

isInstanceKey : String -> Bool
isInstanceKey key = contains "|" key

namesHead : Route -> Bool
namesHead (RKey key ds ms) =
  not (isInstanceKey key) || anyList namesHead ds || anyList namesHead ms
namesHead (RLocal _ ds) = anyList namesHead ds
namesHead (RProj r _) = namesHead r
namesHead _ = False

hasUnroutedPart : Route -> Bool
hasUnroutedPart (RKey _ ds ms) =
  anyList (r => isUnrouted r || hasUnroutedPart r) (ds ++ ms)
hasUnroutedPart (RLocal _ ds) =
  anyList (r => isUnrouted r || hasUnroutedPart r) ds
hasUnroutedPart (RProj r _) = isUnrouted r || hasUnroutedPart r
hasUnroutedPart _ = False

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
(DData Public "HoleKind" () ((variant "UnroutedMethod" (ConPos)) (variant "HeadTagRoute" (ConPos)) (variant "UnroutedPrerequisite" (ConPos)) (variant "UnroutedDictSlot" (ConPos))) ())
(DImpl true "Eq" ((TyCon "HoleKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "UnroutedMethod") (PCon "UnroutedMethod")) () (EVar "True")) (arm (PTuple (PCon "HeadTagRoute") (PCon "HeadTagRoute")) () (EVar "True")) (arm (PTuple (PCon "UnroutedPrerequisite") (PCon "UnroutedPrerequisite")) () (EVar "True")) (arm (PTuple (PCon "UnroutedDictSlot") (PCon "UnroutedDictSlot")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "HoleKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "UnroutedMethod") () (ELit (LString "UnroutedMethod"))) (arm (PCon "HeadTagRoute") () (ELit (LString "HeadTagRoute"))) (arm (PCon "UnroutedPrerequisite") () (ELit (LString "UnroutedPrerequisite"))) (arm (PCon "UnroutedDictSlot") () (ELit (LString "UnroutedDictSlot")))))))
(DData Public "EvidenceRow" () ((variant "OccurrenceRow" (ConPos (TyCon "String") (TyCon "String") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route")))) (variant "DictAppRow" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Route")))) (variant "SiteRow" (ConPos (TyCon "Route")))) ())
(DTypeSig true "holeKindsOf" (TyFun (TyCon "EvidenceRow") (TyApp (TyCon "List") (TyCon "HoleKind"))))
(DFunDef false "holeKindsOf" ((PCon "OccurrenceRow" PWild (PVar "iface") (PVar "tag") (PVar "impls") (PVar "meths"))) (EBlock (DoLet false false (PVar "dicts") (EBinOp "++" (EVar "impls") (EVar "meths"))) (DoExpr (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "UnroutedMethod") (EBinOp "&&" (EBinOp "/=" (EVar "iface") (ELit (LString ""))) (EApp (EVar "isUnrouted") (EVar "tag")))) (ETuple (EVar "HeadTagRoute") (EBinOp "||" (EApp (EVar "namesHead") (EVar "tag")) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "dicts")))) (ETuple (EVar "UnroutedPrerequisite") (EBinOp "||" (EApp (EVar "hasUnroutedPart") (EVar "tag")) (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "hasUnroutedPart") (EVar "r"))))) (EVar "dicts")))))))))
(DFunDef false "holeKindsOf" ((PCon "DictAppRow" PWild PWild (PVar "routes"))) (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "HeadTagRoute") (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "routes"))) (ETuple (EVar "UnroutedPrerequisite") (EApp (EApp (EVar "anyList") (EVar "hasUnroutedPart")) (EVar "routes"))) (ETuple (EVar "UnroutedDictSlot") (EApp (EApp (EVar "anyList") (EVar "isUnrouted")) (EVar "routes"))))))
(DFunDef false "holeKindsOf" ((PCon "SiteRow" (PVar "r"))) (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "HeadTagRoute") (EApp (EVar "namesHead") (EVar "r"))) (ETuple (EVar "UnroutedPrerequisite") (EApp (EVar "hasUnroutedPart") (EVar "r"))))))
(DTypeSig true "rowHole" (TyFun (TyCon "EvidenceRow") (TyApp (TyCon "Option") (TyTuple (TyCon "HoleKind") (TyCon "String")))))
(DFunDef false "rowHole" ((PVar "row")) (EMatch (EApp (EVar "holeKindsOf") (EVar "row")) (arm (PList) () (EVar "None")) (arm (PCons (PVar "k") PWild) () (EApp (EVar "Some") (ETuple (EVar "k") (EApp (EApp (EVar "holeMessage") (EVar "row")) (EVar "k")))))))
(DTypeSig true "holeMessage" (TyFun (TyCon "EvidenceRow") (TyFun (TyCon "HoleKind") (TyCon "String"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") (PVar "iface") PWild PWild PWild) (PCon "UnroutedMethod")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of `")) (EApp (EVar "display") (EApp (EApp (EVar "bareName") (ELit (LString "::"))) (EVar "iface")))) (ELit (LString "` is selected for this use of `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`; annotate the type it is used at"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") (PVar "iface") PWild PWild PWild) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "noImplFor") (EVar "iface")))) (ELit (LString " is selected for this use of `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`: its dispatch names a type, not an impl"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") PWild PWild PWild PWild) PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "the impl selected for this use of `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` needs a dictionary that no impl or given supplies"))))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " passes the type `"))) (EApp (EVar "display") (EApp (EVar "headOf") (EVar "routes")))) (ELit (LString "` where its "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "namesHead")))) (ELit (LString " constraint needs an impl"))))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "UnroutedDictSlot")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " is missing the dictionary for its "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "isUnrouted")))) (ELit (LString " constraint: no impl or given was selected for it"))))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) PWild) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the impl passed for the ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "hasUnroutedPart")))) (ELit (LString " constraint of "))) (EApp (EVar "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " needs a dictionary that no impl or given supplies"))))
(DFunDef false "holeMessage" ((PCon "SiteRow" (PVar "r")) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (ELit (LString "this operator's dispatch names the type `")) (EApp (EVar "display") (EApp (EVar "headOf") (EListLit (EVar "r"))))) (ELit (LString "`, not an impl"))))
(DFunDef false "holeMessage" ((PCon "SiteRow" PWild) PWild) (ELit (LString "the impl selected for this operator needs a dictionary that no impl or given supplies")))
(DTypeSig false "kindsWhere" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "HoleKind") (TyCon "Bool"))) (TyApp (TyCon "List") (TyCon "HoleKind"))))
(DFunDef false "kindsWhere" ((PVar "cases")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (EVar "snd")) (EVar "cases"))))
(DTypeSig false "isUnrouted" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "isUnrouted" ((PCon "RNone")) (EVar "True"))
(DFunDef false "isUnrouted" (PWild) (EVar "False"))
(DTypeSig false "isInstanceKey" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isInstanceKey" ((PVar "key")) (EApp (EApp (EVar "contains") (ELit (LString "|"))) (EVar "key")))
(DTypeSig false "namesHead" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "namesHead" ((PCon "RKey" (PVar "key") (PVar "ds") (PVar "ms"))) (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isInstanceKey") (EVar "key"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ds"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ms"))))
(DFunDef false "namesHead" ((PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ds")))
(DFunDef false "namesHead" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "namesHead") (EVar "r")))
(DFunDef false "namesHead" (PWild) (EVar "False"))
(DTypeSig false "hasUnroutedPart" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "hasUnroutedPart" ((PCon "RKey" PWild (PVar "ds") (PVar "ms"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "hasUnroutedPart") (EVar "r"))))) (EBinOp "++" (EVar "ds") (EVar "ms"))))
(DFunDef false "hasUnroutedPart" ((PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "hasUnroutedPart") (EVar "r"))))) (EVar "ds")))
(DFunDef false "hasUnroutedPart" ((PCon "RProj" (PVar "r") PWild)) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "hasUnroutedPart") (EVar "r"))))
(DFunDef false "hasUnroutedPart" (PWild) (EVar "False"))
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
(DData Public "HoleKind" () ((variant "UnroutedMethod" (ConPos)) (variant "HeadTagRoute" (ConPos)) (variant "UnroutedPrerequisite" (ConPos)) (variant "UnroutedDictSlot" (ConPos))) ())
(DImpl true "Eq" ((TyCon "HoleKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "UnroutedMethod") (PCon "UnroutedMethod")) () (EVar "True")) (arm (PTuple (PCon "HeadTagRoute") (PCon "HeadTagRoute")) () (EVar "True")) (arm (PTuple (PCon "UnroutedPrerequisite") (PCon "UnroutedPrerequisite")) () (EVar "True")) (arm (PTuple (PCon "UnroutedDictSlot") (PCon "UnroutedDictSlot")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "HoleKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "UnroutedMethod") () (ELit (LString "UnroutedMethod"))) (arm (PCon "HeadTagRoute") () (ELit (LString "HeadTagRoute"))) (arm (PCon "UnroutedPrerequisite") () (ELit (LString "UnroutedPrerequisite"))) (arm (PCon "UnroutedDictSlot") () (ELit (LString "UnroutedDictSlot")))))))
(DData Public "EvidenceRow" () ((variant "OccurrenceRow" (ConPos (TyCon "String") (TyCon "String") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route")))) (variant "DictAppRow" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Route")))) (variant "SiteRow" (ConPos (TyCon "Route")))) ())
(DTypeSig true "holeKindsOf" (TyFun (TyCon "EvidenceRow") (TyApp (TyCon "List") (TyCon "HoleKind"))))
(DFunDef false "holeKindsOf" ((PCon "OccurrenceRow" PWild (PVar "iface") (PVar "tag") (PVar "impls") (PVar "meths"))) (EBlock (DoLet false false (PVar "dicts") (EBinOp "++" (EVar "impls") (EVar "meths"))) (DoExpr (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "UnroutedMethod") (EBinOp "&&" (EBinOp "/=" (EVar "iface") (ELit (LString ""))) (EApp (EVar "isUnrouted") (EVar "tag")))) (ETuple (EVar "HeadTagRoute") (EBinOp "||" (EApp (EVar "namesHead") (EVar "tag")) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "dicts")))) (ETuple (EVar "UnroutedPrerequisite") (EBinOp "||" (EApp (EVar "hasUnroutedPart") (EVar "tag")) (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "hasUnroutedPart") (EVar "r"))))) (EVar "dicts")))))))))
(DFunDef false "holeKindsOf" ((PCon "DictAppRow" PWild PWild (PVar "routes"))) (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "HeadTagRoute") (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "routes"))) (ETuple (EVar "UnroutedPrerequisite") (EApp (EApp (EVar "anyList") (EVar "hasUnroutedPart")) (EVar "routes"))) (ETuple (EVar "UnroutedDictSlot") (EApp (EApp (EVar "anyList") (EVar "isUnrouted")) (EVar "routes"))))))
(DFunDef false "holeKindsOf" ((PCon "SiteRow" (PVar "r"))) (EApp (EVar "kindsWhere") (EListLit (ETuple (EVar "HeadTagRoute") (EApp (EVar "namesHead") (EVar "r"))) (ETuple (EVar "UnroutedPrerequisite") (EApp (EVar "hasUnroutedPart") (EVar "r"))))))
(DTypeSig true "rowHole" (TyFun (TyCon "EvidenceRow") (TyApp (TyCon "Option") (TyTuple (TyCon "HoleKind") (TyCon "String")))))
(DFunDef false "rowHole" ((PVar "row")) (EMatch (EApp (EVar "holeKindsOf") (EVar "row")) (arm (PList) () (EVar "None")) (arm (PCons (PVar "k") PWild) () (EApp (EVar "Some") (ETuple (EVar "k") (EApp (EApp (EVar "holeMessage") (EVar "row")) (EVar "k")))))))
(DTypeSig true "holeMessage" (TyFun (TyCon "EvidenceRow") (TyFun (TyCon "HoleKind") (TyCon "String"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") (PVar "iface") PWild PWild PWild) (PCon "UnroutedMethod")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "bareName") (ELit (LString "::"))) (EVar "iface")))) (ELit (LString "` is selected for this use of `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`; annotate the type it is used at"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") (PVar "iface") PWild PWild PWild) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "noImplFor") (EVar "iface")))) (ELit (LString " is selected for this use of `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`: its dispatch names a type, not an impl"))))
(DFunDef false "holeMessage" ((PCon "OccurrenceRow" (PVar "name") PWild PWild PWild PWild) PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "the impl selected for this use of `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` needs a dictionary that no impl or given supplies"))))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " passes the type `"))) (EApp (EMethodRef "display") (EApp (EVar "headOf") (EVar "routes")))) (ELit (LString "` where its "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "namesHead")))) (ELit (LString " constraint needs an impl"))))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) (PCon "UnroutedDictSlot")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " is missing the dictionary for its "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "isUnrouted")))) (ELit (LString " constraint: no impl or given was selected for it"))))
(DFunDef false "holeMessage" ((PCon "DictAppRow" (PVar "callee") (PVar "ifaces") (PVar "routes")) PWild) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the impl passed for the ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "slotIface") (EVar "ifaces")) (EVar "routes")) (EVar "hasUnroutedPart")))) (ELit (LString " constraint of "))) (EApp (EMethodRef "display") (EApp (EVar "theCall") (EVar "callee")))) (ELit (LString " needs a dictionary that no impl or given supplies"))))
(DFunDef false "holeMessage" ((PCon "SiteRow" (PVar "r")) (PCon "HeadTagRoute")) (EBinOp "++" (EBinOp "++" (ELit (LString "this operator's dispatch names the type `")) (EApp (EMethodRef "display") (EApp (EVar "headOf") (EListLit (EVar "r"))))) (ELit (LString "`, not an impl"))))
(DFunDef false "holeMessage" ((PCon "SiteRow" PWild) PWild) (ELit (LString "the impl selected for this operator needs a dictionary that no impl or given supplies")))
(DTypeSig false "kindsWhere" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "HoleKind") (TyCon "Bool"))) (TyApp (TyCon "List") (TyCon "HoleKind"))))
(DFunDef false "kindsWhere" ((PVar "cases")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (EVar "snd")) (EVar "cases"))))
(DTypeSig false "isUnrouted" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "isUnrouted" ((PCon "RNone")) (EVar "True"))
(DFunDef false "isUnrouted" (PWild) (EVar "False"))
(DTypeSig false "isInstanceKey" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isInstanceKey" ((PVar "key")) (EApp (EApp (EVar "contains") (ELit (LString "|"))) (EVar "key")))
(DTypeSig false "namesHead" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "namesHead" ((PCon "RKey" (PVar "key") (PVar "ds") (PVar "ms"))) (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isInstanceKey") (EVar "key"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ds"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ms"))))
(DFunDef false "namesHead" ((PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EVar "anyList") (EVar "namesHead")) (EVar "ds")))
(DFunDef false "namesHead" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "namesHead") (EVar "r")))
(DFunDef false "namesHead" (PWild) (EVar "False"))
(DTypeSig false "hasUnroutedPart" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "hasUnroutedPart" ((PCon "RKey" PWild (PVar "ds") (PVar "ms"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "hasUnroutedPart") (EVar "r"))))) (EBinOp "++" (EVar "ds") (EVar "ms"))))
(DFunDef false "hasUnroutedPart" ((PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "hasUnroutedPart") (EVar "r"))))) (EVar "ds")))
(DFunDef false "hasUnroutedPart" ((PCon "RProj" (PVar "r") PWild)) (EBinOp "||" (EApp (EVar "isUnrouted") (EVar "r")) (EApp (EVar "hasUnroutedPart") (EVar "r"))))
(DFunDef false "hasUnroutedPart" (PWild) (EVar "False"))
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
