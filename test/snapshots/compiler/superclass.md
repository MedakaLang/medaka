# META
source_lines=139
stages=DESUGAR,MARK
# SOURCE
-- The superclass closure: every predicate a dictionary for one predicate also
-- supplies, reached through the interfaces' declared `requires` clauses.
--
-- One walk, parameterised three ways, so its readers differ only in what they
-- carry and what they collapse:
--
--   * `lookup` answers "what are this interface's type parameters and direct
--     supers".  Readers pass an identity-keyed lookup over the class
--     environment; nothing here scans declarations.
--   * `step` maps one direct `Super` into the payload the reader carries
--     (argument monos, tyvar ids, `Ty`s), given the sub-predicate's
--     type-parameter names and payload.  `None` drops that super, which is how
--     a reader that cannot resolve every super parameter declines it.
--   * `key` renders a node for the dedup that decides which nodes are the same
--     predicate.  The first occurrence in breadth-first order wins.
--
-- Each result node records its projection path: the seed's position in the
-- input followed by the index of each direct super taken, so a superclass
-- predicate can be named as a projection of the seed's evidence rather than
-- selected again.

import frontend.ast.{Super(..)}
import types.repr.{IfaceRef}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omInsert}

-- One predicate in a closure.  `superPath` is empty for nothing: a seed's path
-- is `[seedIndex]`, and each super step appends the direct-super index.
public export data SuperNode p = SuperNode {
  superPath : List Int,
  superIface : IfaceRef,
  superPayload : p,
}

-- The seeds followed by their transitive supers, breadth-first, deduplicated by
-- `key` (seeds included; the first occurrence of a key wins).
export
superClosure : (IfaceRef -> Option (List String, List Super)) ->
  (List String -> p -> Super -> Option p) ->
  (IfaceRef -> p -> String) ->
  List (IfaceRef, p) ->
  List (SuperNode p)
superClosure lookup step key seeds =
  let seedNodes = seedNodesFrom 0 seeds
  let (kept, seen) = keepFresh key seedNodes omEmpty
  closureLayers lookup step key kept seen kept

-- The direct supers of one node, in declaration order, each carrying its path.
export
directSupers : (IfaceRef -> Option (List String, List Super)) ->
  (List String -> p -> Super -> Option p) ->
  SuperNode p ->
  List (SuperNode p)
directSupers lookup step node = match lookup node.superIface
  None => []
  Some (typarams, supers) => directSupersFrom step typarams node 0 supers

-- A `Super`'s identity as an interface reference.
export
superIfaceRef : Super -> IfaceRef
superIfaceRef (Super { superHead, superOrigin, ... }) =
  IfaceRef { irName = superHead, irOrigin = superOrigin }

-- Position of [name] in [names], mapped onto the same position of [values].
-- `None` when the name is absent or the value list is shorter.
export
lookupPos : String -> List String -> List a -> Option a
lookupPos _ [] _ = None
lookupPos _ _ [] = None
lookupPos name (n :: ns) (v :: vs)
  | n == name = Some v
  | otherwise = lookupPos name ns vs

-- `Some` of every image when [f] succeeds on all of [xs], else `None`.
export
mapAll : (a -> Option b) -> List a -> Option (List b)
mapAll _ [] = Some []
mapAll f (x :: xs) = match f x
  None => None
  Some y => map (y :: _) (mapAll f xs)

seedNodesFrom : Int -> List (IfaceRef, p) -> List (SuperNode p)
seedNodesFrom _ [] = []
seedNodesFrom i ((iface, payload) :: rest) =
  SuperNode { superPath = [i], superIface = iface, superPayload = payload }
    :: seedNodesFrom (i + 1) rest

directSupersFrom : (List String -> p -> Super -> Option p) ->
  List String ->
  SuperNode p ->
  Int ->
  List Super ->
  List (SuperNode p)
directSupersFrom _ _ _ _ [] = []
directSupersFrom step typarams node i (s :: rest) =
  let tailNodes = directSupersFrom step typarams node (i + 1) rest
  match step typarams node.superPayload s
    None => tailNodes
    Some payload =>
      SuperNode {
          superPath = node.superPath ++ [i],
          superIface = superIfaceRef s,
          superPayload = payload,
        }
        :: tailNodes

-- Breadth-first: expand the whole frontier, keep the unseen nodes in order,
-- append them, repeat until a layer adds nothing.  Declared supers are
-- acyclic (W1), and the dedup set bounds the walk regardless.
closureLayers : (IfaceRef -> Option (List String, List Super)) ->
  (List String -> p -> Super -> Option p) ->
  (IfaceRef -> p -> String) ->
  List (SuperNode p) ->
  OrdMap Bool ->
  List (SuperNode p) ->
  List (SuperNode p)
closureLayers _ _ _ acc _ [] = acc
closureLayers lookup step key acc seen frontier =
  let candidates = flatMapNodes (directSupers lookup step) frontier
  let (fresh, seen2) = keepFresh key candidates seen
  closureLayers lookup step key (acc ++ fresh) seen2 fresh

flatMapNodes : (SuperNode p -> List (SuperNode p)) ->
  List (SuperNode p) ->
  List (SuperNode p)
flatMapNodes _ [] = []
flatMapNodes f (n :: rest) = f n ++ flatMapNodes f rest

keepFresh : (IfaceRef -> p -> String) ->
  List (SuperNode p) ->
  OrdMap Bool ->
  (List (SuperNode p), OrdMap Bool)
keepFresh _ [] seen = ([], seen)
keepFresh key (n :: rest) seen =
  let k = key n.superIface n.superPayload
  if omHasKey k seen then
    keepFresh key rest seen
  else
    let (kept, seen2) = keepFresh key rest (omInsert k True seen)
    (n :: kept, seen2)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Super" true))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false))))
(DData Public "SuperNode" ("p") ((variant "SuperNode" (ConNamed (field "superPath" (TyApp (TyCon "List") (TyCon "Int"))) (field "superIface" (TyCon "IfaceRef")) (field "superPayload" (TyVar "p"))))) ())
(DTypeSig true "superClosure" (TyFun (TyFun (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Super"))))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyVar "p") (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyVar "p"))))) (TyFun (TyFun (TyCon "IfaceRef") (TyFun (TyVar "p") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyVar "p"))) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))))))))
(DFunDef false "superClosure" ((PVar "lookup") (PVar "step") (PVar "key") (PVar "seeds")) (EBlock (DoLet false false (PVar "seedNodes") (EApp (EApp (EVar "seedNodesFrom") (ELit (LInt 0))) (EVar "seeds"))) (DoLet false false (PTuple (PVar "kept") (PVar "seen")) (EApp (EApp (EApp (EVar "keepFresh") (EVar "key")) (EVar "seedNodes")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "closureLayers") (EVar "lookup")) (EVar "step")) (EVar "key")) (EVar "kept")) (EVar "seen")) (EVar "kept")))))
(DTypeSig true "directSupers" (TyFun (TyFun (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Super"))))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyVar "p") (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyVar "p"))))) (TyFun (TyApp (TyCon "SuperNode") (TyVar "p")) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p")))))))
(DFunDef false "directSupers" ((PVar "lookup") (PVar "step") (PVar "node")) (EMatch (EApp (EVar "lookup") (EFieldAccess (EVar "node") "superIface")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "typarams") (PVar "supers"))) () (EApp (EApp (EApp (EApp (EApp (EVar "directSupersFrom") (EVar "step")) (EVar "typarams")) (EVar "node")) (ELit (LInt 0))) (EVar "supers")))))
(DTypeSig true "superIfaceRef" (TyFun (TyCon "Super") (TyCon "IfaceRef")))
(DFunDef false "superIfaceRef" ((PRec "Super" ((rf "superHead" None) (rf "superOrigin" None)) true)) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "superHead")) (fa "irOrigin" (EVar "superOrigin")))))
(DTypeSig true "lookupPos" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "lookupPos" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "lookupPos" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupPos" ((PVar "name") (PCons (PVar "n") (PVar "ns")) (PCons (PVar "v") (PVar "vs"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupPos") (EVar "name")) (EVar "ns")) (EVar "vs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "mapAll" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "Option") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "b"))))))
(DFunDef false "mapAll" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "mapAll" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EMatch (EApp (EVar "f") (EVar "x")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "y")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "y") (EVar "_s")))) (EApp (EApp (EVar "mapAll") (EVar "f")) (EVar "xs"))))))
(DTypeSig false "seedNodesFrom" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyVar "p"))) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))))))
(DFunDef false "seedNodesFrom" (PWild (PList)) (EListLit))
(DFunDef false "seedNodesFrom" ((PVar "i") (PCons (PTuple (PVar "iface") (PVar "payload")) (PVar "rest"))) (EBinOp "::" (ERecordCreate "SuperNode" ((fa "superPath" (EListLit (EVar "i"))) (fa "superIface" (EVar "iface")) (fa "superPayload" (EVar "payload")))) (EApp (EApp (EVar "seedNodesFrom") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "directSupersFrom" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyVar "p") (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyVar "p"))))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "SuperNode") (TyVar "p")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p")))))))))
(DFunDef false "directSupersFrom" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "directSupersFrom" ((PVar "step") (PVar "typarams") (PVar "node") (PVar "i") (PCons (PVar "s") (PVar "rest"))) (EBlock (DoLet false false (PVar "tailNodes") (EApp (EApp (EApp (EApp (EApp (EVar "directSupersFrom") (EVar "step")) (EVar "typarams")) (EVar "node")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "step") (EVar "typarams")) (EFieldAccess (EVar "node") "superPayload")) (EVar "s")) (arm (PCon "None") () (EVar "tailNodes")) (arm (PCon "Some" (PVar "payload")) () (EBinOp "::" (ERecordCreate "SuperNode" ((fa "superPath" (EBinOp "++" (EFieldAccess (EVar "node") "superPath") (EListLit (EVar "i")))) (fa "superIface" (EApp (EVar "superIfaceRef") (EVar "s"))) (fa "superPayload" (EVar "payload")))) (EVar "tailNodes")))))))
(DTypeSig false "closureLayers" (TyFun (TyFun (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Super"))))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyVar "p") (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyVar "p"))))) (TyFun (TyFun (TyCon "IfaceRef") (TyFun (TyVar "p") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))))))))))
(DFunDef false "closureLayers" (PWild PWild PWild (PVar "acc") PWild (PList)) (EVar "acc"))
(DFunDef false "closureLayers" ((PVar "lookup") (PVar "step") (PVar "key") (PVar "acc") (PVar "seen") (PVar "frontier")) (EBlock (DoLet false false (PVar "candidates") (EApp (EApp (EVar "flatMapNodes") (EApp (EApp (EVar "directSupers") (EVar "lookup")) (EVar "step"))) (EVar "frontier"))) (DoLet false false (PTuple (PVar "fresh") (PVar "seen2")) (EApp (EApp (EApp (EVar "keepFresh") (EVar "key")) (EVar "candidates")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "closureLayers") (EVar "lookup")) (EVar "step")) (EVar "key")) (EBinOp "++" (EVar "acc") (EVar "fresh"))) (EVar "seen2")) (EVar "fresh")))))
(DTypeSig false "flatMapNodes" (TyFun (TyFun (TyApp (TyCon "SuperNode") (TyVar "p")) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p")))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))))))
(DFunDef false "flatMapNodes" (PWild (PList)) (EListLit))
(DFunDef false "flatMapNodes" ((PVar "f") (PCons (PVar "n") (PVar "rest"))) (EBinOp "++" (EApp (EVar "f") (EVar "n")) (EApp (EApp (EVar "flatMapNodes") (EVar "f")) (EVar "rest"))))
(DTypeSig false "keepFresh" (TyFun (TyFun (TyCon "IfaceRef") (TyFun (TyVar "p") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))) (TyApp (TyCon "OrdMap") (TyCon "Bool")))))))
(DFunDef false "keepFresh" (PWild (PList) (PVar "seen")) (ETuple (EListLit) (EVar "seen")))
(DFunDef false "keepFresh" ((PVar "key") (PCons (PVar "n") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "key") (EFieldAccess (EVar "n") "superIface")) (EFieldAccess (EVar "n") "superPayload"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (EApp (EApp (EApp (EVar "keepFresh") (EVar "key")) (EVar "rest")) (EVar "seen")) (EBlock (DoLet false false (PTuple (PVar "kept") (PVar "seen2")) (EApp (EApp (EApp (EVar "keepFresh") (EVar "key")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EVar "True")) (EVar "seen")))) (DoExpr (ETuple (EBinOp "::" (EVar "n") (EVar "kept")) (EVar "seen2"))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Super" true))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false))))
(DData Public "SuperNode" ("p") ((variant "SuperNode" (ConNamed (field "superPath" (TyApp (TyCon "List") (TyCon "Int"))) (field "superIface" (TyCon "IfaceRef")) (field "superPayload" (TyVar "p"))))) ())
(DTypeSig true "superClosure" (TyFun (TyFun (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Super"))))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyVar "p") (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyVar "p"))))) (TyFun (TyFun (TyCon "IfaceRef") (TyFun (TyVar "p") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyVar "p"))) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))))))))
(DFunDef false "superClosure" ((PVar "lookup") (PVar "step") (PVar "key") (PVar "seeds")) (EBlock (DoLet false false (PVar "seedNodes") (EApp (EApp (EVar "seedNodesFrom") (ELit (LInt 0))) (EVar "seeds"))) (DoLet false false (PTuple (PVar "kept") (PVar "seen")) (EApp (EApp (EApp (EVar "keepFresh") (EVar "key")) (EVar "seedNodes")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "closureLayers") (EVar "lookup")) (EVar "step")) (EVar "key")) (EVar "kept")) (EVar "seen")) (EVar "kept")))))
(DTypeSig true "directSupers" (TyFun (TyFun (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Super"))))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyVar "p") (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyVar "p"))))) (TyFun (TyApp (TyCon "SuperNode") (TyVar "p")) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p")))))))
(DFunDef false "directSupers" ((PVar "lookup") (PVar "step") (PVar "node")) (EMatch (EApp (EVar "lookup") (EFieldAccess (EVar "node") "superIface")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "typarams") (PVar "supers"))) () (EApp (EApp (EApp (EApp (EApp (EVar "directSupersFrom") (EVar "step")) (EVar "typarams")) (EVar "node")) (ELit (LInt 0))) (EVar "supers")))))
(DTypeSig true "superIfaceRef" (TyFun (TyCon "Super") (TyCon "IfaceRef")))
(DFunDef false "superIfaceRef" ((PRec "Super" ((rf "superHead" None) (rf "superOrigin" None)) true)) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "superHead")) (fa "irOrigin" (EVar "superOrigin")))))
(DTypeSig true "lookupPos" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "lookupPos" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "lookupPos" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupPos" ((PVar "name") (PCons (PVar "n") (PVar "ns")) (PCons (PVar "v") (PVar "vs"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupPos") (EVar "name")) (EVar "ns")) (EVar "vs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "mapAll" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "Option") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "b"))))))
(DFunDef false "mapAll" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "mapAll" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EMatch (EApp (EVar "f") (EVar "x")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "y")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "y") (EVar "_s")))) (EApp (EApp (EVar "mapAll") (EVar "f")) (EVar "xs"))))))
(DTypeSig false "seedNodesFrom" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyVar "p"))) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))))))
(DFunDef false "seedNodesFrom" (PWild (PList)) (EListLit))
(DFunDef false "seedNodesFrom" ((PVar "i") (PCons (PTuple (PVar "iface") (PVar "payload")) (PVar "rest"))) (EBinOp "::" (ERecordCreate "SuperNode" ((fa "superPath" (EListLit (EVar "i"))) (fa "superIface" (EVar "iface")) (fa "superPayload" (EVar "payload")))) (EApp (EApp (EVar "seedNodesFrom") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "directSupersFrom" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyVar "p") (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyVar "p"))))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "SuperNode") (TyVar "p")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p")))))))))
(DFunDef false "directSupersFrom" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "directSupersFrom" ((PVar "step") (PVar "typarams") (PVar "node") (PVar "i") (PCons (PVar "s") (PVar "rest"))) (EBlock (DoLet false false (PVar "tailNodes") (EApp (EApp (EApp (EApp (EApp (EVar "directSupersFrom") (EVar "step")) (EVar "typarams")) (EVar "node")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "step") (EVar "typarams")) (EFieldAccess (EVar "node") "superPayload")) (EVar "s")) (arm (PCon "None") () (EVar "tailNodes")) (arm (PCon "Some" (PVar "payload")) () (EBinOp "::" (ERecordCreate "SuperNode" ((fa "superPath" (EBinOp "++" (EFieldAccess (EVar "node") "superPath") (EListLit (EVar "i")))) (fa "superIface" (EApp (EVar "superIfaceRef") (EVar "s"))) (fa "superPayload" (EVar "payload")))) (EVar "tailNodes")))))))
(DTypeSig false "closureLayers" (TyFun (TyFun (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Super"))))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyVar "p") (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyVar "p"))))) (TyFun (TyFun (TyCon "IfaceRef") (TyFun (TyVar "p") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))))))))))
(DFunDef false "closureLayers" (PWild PWild PWild (PVar "acc") PWild (PList)) (EVar "acc"))
(DFunDef false "closureLayers" ((PVar "lookup") (PVar "step") (PVar "key") (PVar "acc") (PVar "seen") (PVar "frontier")) (EBlock (DoLet false false (PVar "candidates") (EApp (EApp (EVar "flatMapNodes") (EApp (EApp (EVar "directSupers") (EVar "lookup")) (EVar "step"))) (EVar "frontier"))) (DoLet false false (PTuple (PVar "fresh") (PVar "seen2")) (EApp (EApp (EApp (EVar "keepFresh") (EVar "key")) (EVar "candidates")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "closureLayers") (EVar "lookup")) (EVar "step")) (EVar "key")) (EBinOp "++" (EVar "acc") (EVar "fresh"))) (EVar "seen2")) (EVar "fresh")))))
(DTypeSig false "flatMapNodes" (TyFun (TyFun (TyApp (TyCon "SuperNode") (TyVar "p")) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p")))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))) (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))))))
(DFunDef false "flatMapNodes" (PWild (PList)) (EListLit))
(DFunDef false "flatMapNodes" ((PVar "f") (PCons (PVar "n") (PVar "rest"))) (EBinOp "++" (EApp (EVar "f") (EVar "n")) (EApp (EApp (EVar "flatMapNodes") (EVar "f")) (EVar "rest"))))
(DTypeSig false "keepFresh" (TyFun (TyFun (TyCon "IfaceRef") (TyFun (TyVar "p") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "SuperNode") (TyVar "p"))) (TyApp (TyCon "OrdMap") (TyCon "Bool")))))))
(DFunDef false "keepFresh" (PWild (PList) (PVar "seen")) (ETuple (EListLit) (EVar "seen")))
(DFunDef false "keepFresh" ((PVar "key") (PCons (PVar "n") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EVar "key") (EFieldAccess (EVar "n") "superIface")) (EFieldAccess (EVar "n") "superPayload"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (EApp (EApp (EApp (EVar "keepFresh") (EVar "key")) (EVar "rest")) (EVar "seen")) (EBlock (DoLet false false (PTuple (PVar "kept") (PVar "seen2")) (EApp (EApp (EApp (EVar "keepFresh") (EVar "key")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EVar "True")) (EVar "seen")))) (DoExpr (ETuple (EBinOp "::" (EVar "n") (EVar "kept")) (EVar "seen2"))))))))
