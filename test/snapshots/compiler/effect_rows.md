# META
source_lines=434
stages=DESUGAR,MARK
# SOURCE
-- Effect atoms and rows. An atom is a resolved label refined by an authority
-- term; a row is a finite label map plus an optional tail. Two atoms on one
-- label are never two members: they collapse to one by the authority join.
-- A row's tail is a DAG of cells; a join retains every member's atoms, since
-- compressing it to only its unbound leaves would erase effects.

import support.util.{reverseL, joinWith}
import support.opcount.{opBump}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup, omKeys}
import types.effect_domain.{Param}
import types.effect_authority.{
  Authority(..), Authvar, authJoin, authSub, authConst, renderAuthority,
  authvarDefaultName, authNorm, renderAuthorityWith
}
import frontend.ast.{TyConOrigin(..)}
import map.{Map(..), has, set}

-- A label is its spelling together with the identity of the declaration it
-- names: `OriginBuiltin` for the language's own labels, the declaring module
-- for a user `effect`, unresolved in a flat program. The key an atom map uses
-- is the identity, so two modules' same-spelled labels are two atoms.
public export data EffLabel = EffLabel String TyConOrigin

public export data Atom = Atom EffLabel Authority

export
effLabelName : EffLabel -> String
effLabelName (EffLabel n _) = n

export
effLabelOrigin : EffLabel -> TyConOrigin
effLabelOrigin (EffLabel _ o) = o

export
labelKey : EffLabel -> String
labelKey (EffLabel n o) = match o
  OriginModule m => "\{m}::\{n}"
  _ => n

export
builtinLabel : String -> EffLabel
builtinLabel n = EffLabel n OriginBuiltin

export
atomLabel : Atom -> String
atomLabel (Atom l _) = effLabelName l

export
atomLabelOf : Atom -> EffLabel
atomLabelOf (Atom l _) = l

export
atomKey : Atom -> String
atomKey (Atom l _) = labelKey l

export
atomAuth : Atom -> Authority
atomAuth (Atom _ a) = a

-- The concrete parameter an atom carries, when nothing symbolic is left in it.
export
atomConst : Atom -> Option Param
atomConst (Atom _ a) = authConst a

export
atomBuiltin : String -> Param -> Atom
atomBuiltin n p = Atom (builtinLabel n) (AConst p)

export
atomWith : EffLabel -> Param -> Atom
atomWith l p = Atom l (AConst p)

-- Rendering order is by spelling first, then by identity, so a row prints the
-- way it always has and only a genuine same-spelling collision orders by module.
sortKey : Atom -> String
sortKey a = "\{atomLabel a} \{atomKey a}"

export
renderAtom : Atom -> String
renderAtom a = renderAtomWith authvarDefaultName a

-- An atom whose authority is a symbolic join renders as one atom per operand
-- (`FileWrite dst, FileWrite src`), the spelling a signature writes and the
-- parser folds back into one atom; the join form ` (a | b)` is not one.
export
renderAtomWith : (Ref Authvar -> String) -> Atom -> String
renderAtomWith name a = match authNorm (atomAuth a)
  AJoin ms =>
    joinWith ", " (map (m => atomLabel a ++ renderAuthorityWith name m) ms)
  q => atomLabel a ++ renderAuthorityWith name q

export
renderAtoms : List Atom -> String
renderAtoms atoms = joinWith ", " (map renderAtom (atomsNorm atoms))

export
renderAtomsWith : (Ref Authvar -> String) -> List Atom -> String
renderAtomsWith name atoms =
  joinWith ", " (map (renderAtomWith name) (atomsNorm atoms))

export
atomInsert : Atom -> List Atom -> List Atom
atomInsert x [] = [x]
atomInsert x (y :: ys) = match stringCompare (sortKey x) (sortKey y)
  Lt => x :: y :: ys
  Eq => Atom (atomLabelOf y) (authJoin (atomAuth x) (atomAuth y)) :: ys
  Gt => y :: atomInsert x ys

export
atomsNorm : List Atom -> List Atom
atomsNorm [] = []
atomsNorm [x] = [x]
atomsNorm [x, y] = atomInsert y [x]
atomsNorm [x, y, z] = atomInsert z (atomInsert y [x])
atomsNorm xs = atomsFromIndex (atomIndex xs omEmpty)

-- Rows normally contain one or two labels, where a tree would be needless
-- allocation. Once a row grows past that fixed small case, index by the sort
-- key. The map's in-order keys also retain the canonical rendering order.
-- `authJoin x old` deliberately matches atomInsert: a later occurrence is
-- joined into the earlier one in the same direction.
atomIndex : List Atom -> OrdMap Atom -> OrdMap Atom
atomIndex [] m = m
atomIndex (x :: xs) m =
  let k = sortKey x
  let next = match omLookup k m
    None => x
    Some old => Atom (atomLabelOf old) (authJoin (atomAuth x) (atomAuth old))
  atomIndex xs (omInsert k next m)

atomIndexFirst : List Atom -> OrdMap Atom -> OrdMap Atom
atomIndexFirst [] m = m
atomIndexFirst (x :: xs) m = match omLookup (sortKey x) m
  None => atomIndexFirst xs (omInsert (sortKey x) x m)
  Some _ => atomIndexFirst xs m

atomsFromIndex : OrdMap Atom -> List Atom
atomsFromIndex m = atomsFromKeys (omKeys m) m

atomsFromKeys : List String -> OrdMap Atom -> List Atom
atomsFromKeys [] _ = []
atomsFromKeys (k :: ks) m = match omLookup k m
  Some atom => atom :: atomsFromKeys ks m
  None => atomsFromKeys ks m

export
atomsUnion : List Atom -> List Atom -> List Atom
atomsUnion a b = atomsNorm (a ++ b)

-- The atoms of [xs] not proven covered by [ys]: a label absent from [ys], or
-- present with an authority that does not provably cover. A symbolic pair
-- that cannot be decided yet stays in the difference; the caller decides
-- whether that is an escape or a pending obligation.
export
atomsDiff : List Atom -> List Atom -> List Atom
atomsDiff [] _ = []
atomsDiff xs [] = xs
atomsDiff [x] ys = atomsDiffOne x ys
atomsDiff [x, y] ys = atomsDiffOne x ys ++ atomsDiffOne y ys
atomsDiff xs [y] = atomsDiffOneAgainst xs y
atomsDiff xs ys = reverseL (atomsDiffIndexed xs (atomIndexFirst ys omEmpty) [])

atomsDiffOne : Atom -> List Atom -> List Atom
atomsDiffOne x ys = match findAtom (atomKey x) ys
  None => [x]
  Some y => if authSub (atomAuth x) (atomAuth y) then [] else [x]

atomsDiffOneAgainst : List Atom -> Atom -> List Atom
atomsDiffOneAgainst xs y = reverseL (atomsDiffOneAgainstGo xs y [])

atomsDiffOneAgainstGo : List Atom -> Atom -> List Atom -> List Atom
atomsDiffOneAgainstGo [] _ acc = acc
atomsDiffOneAgainstGo (x :: xs) y acc =
  if atomKey x == atomKey y && authSub (atomAuth x) (atomAuth y) then
    atomsDiffOneAgainstGo xs y acc
  else
    atomsDiffOneAgainstGo xs y (x :: acc)

atomsDiffIndexed : List Atom -> OrdMap Atom -> List Atom -> List Atom
atomsDiffIndexed [] _ acc = acc
atomsDiffIndexed (x :: xs) index acc = match omLookup (sortKey x) index
  Some y =>
    if authSub (atomAuth x) (atomAuth y) then
      atomsDiffIndexed xs index acc
    else
      atomsDiffIndexed xs index (x :: acc)
  None => atomsDiffIndexed xs index (x :: acc)

-- The atom whose label has identity key [k], by first occurrence.
export
findAtom : String -> List Atom -> Option Atom
findAtom _ [] = None
findAtom k (y :: ys) = if k == atomKey y then Some y else findAtom k ys

-- ── rows ──────────────────────────────────────────────────────────────────

public export data EffRow = EffRow (List Atom) (Option (Ref Effvar))

public export data Effvar =
  | EUnbound Int Int
  | ELink Int EffRow
  | EJoin Int Int (List (Ref Effvar))
  | ESummary Int Int Int

export
effrowNorm : EffRow -> EffRow
effrowNorm (row@(EffRow _ None)) = row
effrowNorm (row@(EffRow _ (Some cell))) = match !cell
  EUnbound _ _ => row
  ESummary _ _ _ => row
  _ =>
    let (labels, members) = rowFlat row
    match members
      [] => EffRow labels None
      [member] => EffRow labels (Some member)
      _ => EffRow labels (Some (rowRepresentative cell))

-- After flattening leaves more than one tail, the tail-chain representative
-- must be a join. Returning an ELink here would hide that fact from solvers.
rowRepresentative : Ref Effvar -> Ref Effvar
rowRepresentative cell = match !cell
  ELink _ (EffRow _ (Some next)) => rowRepresentative next
  _ => cell

-- Compress link chains without expanding joins. Expanding a shared join here
-- would start a fresh visited set for each incoming link and defeat DAG sharing.
-- Only empty-prefix links can share a normalized suffix without copying its
-- atoms. Stop before a labelled node to retain its shared identity. Materializing every suffix of a
-- distinct-label chain would allocate quadratically. rowFlat joins them once.
compressLink : Ref Effvar -> EffRow -> EffRow
compressLink cell (row@(EffRow [] (Some next))) = match !next
  ELink _ (nextRow@(EffRow [] _)) =>
    let target = compressLink next nextRow
    linkRow cell target
    target
  _ => row
compressLink _ row = row

export
effrowLabels : EffRow -> List Atom
effrowLabels r = match effrowNorm r
  EffRow labels _ => labels

-- Sequencing is a join, never an equation between the performed computations.
-- The allocator supplies a request-owned join identity; input cells are read
-- but not linked, closed or narrowed by effect accumulation.
export
joinRows : (List (Ref Effvar) -> Ref Effvar) -> EffRow -> EffRow -> EffRow
joinRows _ (EffRow [] None) right = right
joinRows _ left (EffRow [] None) = left
joinRows makeJoin left right = collectRows makeJoin [left, right]

-- Captures prepend performed rows in constant time and finalize once. Flatten
-- the whole collection with one visited set, including shared row DAGs.
export
collectRows : (List (Ref Effvar) -> Ref Effvar) -> List EffRow -> EffRow
collectRows makeJoin rows =
  let (atoms, cells) = rowFlatGo rows (Seen Tip Tip) [] []
  match cells
    [] => EffRow atoms None
    [cell] => EffRow atoms (Some cell)
    cells => EffRow atoms (Some (makeJoin cells))

export
effvarId : Ref Effvar -> Int
effvarId cell = match !cell
  EUnbound id _ => id
  ELink id _ => id
  EJoin id _ _ => id
  ESummary id _ _ => id

-- Identity belongs to the cell, not its current contents. Links retain it so
-- a shared labelled suffix is visited once even after inference solves it.
export
linkRow : Ref Effvar -> EffRow -> Unit
linkRow cell row = match !cell
  ESummary _ _ _ => panic "effect summary mutated by ordinary row unification"
  _ => cell := ELink (effvarId cell) row

export
solveSummaryCell : Int -> Ref Effvar -> EffRow -> Unit
solveSummaryCell owner cell row = match !cell
  ESummary id _ actualOwner if owner == actualOwner => cell := ELink id row
  _ => panic "effect summary solved outside its owning scope"

export
rowHasSummary : EffRow -> Bool
rowHasSummary row = hasSummaryRows [row] Tip

hasSummaryRows : List EffRow -> Map Int Unit -> Bool
hasSummaryRows [] _ = False
hasSummaryRows ((EffRow _ None) :: rest) seen = hasSummaryRows rest seen
hasSummaryRows ((EffRow _ (Some cell)) :: rest) seen = match !cell
  ESummary _ _ _ => True
  EUnbound _ _ => hasSummaryRows rest seen
  ELink id row =>
    if has id seen then
      hasSummaryRows rest seen
    else
      hasSummaryRows (row :: rest) (set id () seen)
  EJoin id _ members =>
    if has id seen then
      hasSummaryRows rest seen
    else
      hasSummaryRows (pushMembers members rest) (set id () seen)

export
isJoinCell : Ref Effvar -> Bool
isJoinCell cell = match !cell
  EJoin _ _ _ => True
  _ => False

export
rowFlat : EffRow -> (List Atom, List (Ref Effvar))
rowFlat row = rowFlatGo [row] (Seen Tip Tip) [] []

export
rowFlatMembers : List Atom ->
  List (Ref Effvar) ->
  (List Atom, List (Ref Effvar))
rowFlatMembers labels members =
  rowFlatGo (EffRow labels None :: pushMembers members []) (Seen Tip Tip) [] []

-- A row tail is a DAG: joins deliberately share member cells.  Traversing a
-- shared join once per incoming edge is exponential for a diamond-shaped row.
-- IDs are allocated from one request-owned supply and survive solving/linking.
-- Sharing applies to label-bearing links as well as joins: visiting a common
-- N-label suffix for each of M incoming edges would otherwise cost O(M*N).
data Seen = Seen (Map Int Unit) (Map Int Unit)

seenUnbound : Int -> Seen -> Bool
seenUnbound id (Seen unbounds _) = has id unbounds

seenJoin : Int -> Seen -> Bool
seenJoin id (Seen _ joins) = has id joins

markUnbound : Int -> Seen -> Seen
markUnbound id (Seen unbounds joins) = Seen (set id () unbounds) joins

markJoin : Int -> Seen -> Seen
markJoin id (Seen unbounds joins) = Seen unbounds (set id () joins)

-- `pending` is a stack.  Reverse first so a join's members still visit left to
-- right, which retains the old first-occurrence order for its live tail cells.
pushMembers : List (Ref Effvar) -> List EffRow -> List EffRow
pushMembers members pending = pushMembersRev (reverseL members) pending

pushMembersRev : List (Ref Effvar) -> List EffRow -> List EffRow
pushMembersRev [] pending = pending
pushMembersRev (member :: members) pending =
  pushMembersRev members (EffRow [] (Some member) :: pending)

addLabels : List Atom -> List (List Atom) -> List (List Atom)
addLabels [] chunks = chunks
addLabels labels chunks = labels :: chunks

-- The chunks are accumulated in reverse visitation order.  Prepending each
-- original chunk restores exact left-to-right atom input without any repeated
-- list append; atomsUnion normalises just once at the end.
flattenChunks : List (List Atom) -> List Atom -> List Atom
flattenChunks [] acc = acc
flattenChunks (chunk :: chunks) acc =
  flattenChunks chunks (prependChunk chunk acc)

prependChunk : List Atom -> List Atom -> List Atom
prependChunk chunk acc = prependChunkRev (reverseL chunk) acc

prependChunkRev : List Atom -> List Atom -> List Atom
prependChunkRev [] acc = acc
prependChunkRev (atom :: atoms) acc = prependChunkRev atoms (atom :: acc)

rowFlatGo : List EffRow ->
  Seen ->
  List (List Atom) ->
  List (Ref Effvar) ->
  (List Atom, List (Ref Effvar))
rowFlatGo [] _ chunks cells = (finishChunks chunks, reverseL cells)
rowFlatGo ((EffRow labels tail) :: pending) seen chunks cells =
  let _ = opBump ()
  let chunks2 = addLabels labels chunks
  match tail
    None => rowFlatGo pending seen chunks2 cells
    Some cell => match !cell
      EUnbound id _ =>
        if seenUnbound id seen then
          rowFlatGo pending seen chunks2 cells
        else
          rowFlatGo pending (markUnbound id seen) chunks2 (cell :: cells)
      ESummary id _ _ =>
        if seenUnbound id seen then
          rowFlatGo pending seen chunks2 cells
        else
          rowFlatGo pending (markUnbound id seen) chunks2 (cell :: cells)
      ELink id row =>
        if seenJoin id seen then
          rowFlatGo pending seen chunks2 cells
        else
          rowFlatGo
            (compressLink cell row :: pending)
            (markJoin id seen)
            chunks2
            cells
      EJoin id _ members =>
        if seenJoin id seen then
          rowFlatGo pending seen chunks2 cells
        else
          rowFlatGo
            (pushMembers members pending)
            (markJoin id seen)
            chunks2
            cells

finishChunks : List (List Atom) -> List Atom
finishChunks [] = []
finishChunks [labels] = labels
finishChunks chunks = atomsUnion [] (flattenChunks chunks [])

export
dedupCells : List (Ref Effvar) -> List (Ref Effvar)
dedupCells cells = reverseL (dedupCellsGo cells Tip [])

-- `rowFlat` returns unbound cells, but this public helper is also used while
-- constructing joins. Keep the first cell for each stable identity.
dedupCellsGo : List (Ref Effvar) ->
  Map Int Unit ->
  List (Ref Effvar) ->
  List (Ref Effvar)
dedupCellsGo [] _ acc = acc
dedupCellsGo (cell :: cells) seen acc =
  let id = effvarId cell
  if has id seen then
    dedupCellsGo cells seen acc
  else
    dedupCellsGo cells (set id () seen) (cell :: acc)
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("support" "opcount") ((mem "opBump" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" false) (mem "authJoin" false) (mem "authSub" false) (mem "authConst" false) (mem "renderAuthority" false) (mem "authvarDefaultName" false) (mem "authNorm" false) (mem "renderAuthorityWith" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true))))
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "has" false) (mem "set" false))))
(DData Public "EffLabel" () ((variant "EffLabel" (ConPos (TyCon "String") (TyCon "TyConOrigin")))) ())
(DData Public "Atom" () ((variant "Atom" (ConPos (TyCon "EffLabel") (TyCon "Authority")))) ())
(DTypeSig true "effLabelName" (TyFun (TyCon "EffLabel") (TyCon "String")))
(DFunDef false "effLabelName" ((PCon "EffLabel" (PVar "n") PWild)) (EVar "n"))
(DTypeSig true "effLabelOrigin" (TyFun (TyCon "EffLabel") (TyCon "TyConOrigin")))
(DFunDef false "effLabelOrigin" ((PCon "EffLabel" PWild (PVar "o"))) (EVar "o"))
(DTypeSig true "labelKey" (TyFun (TyCon "EffLabel") (TyCon "String")))
(DFunDef false "labelKey" ((PCon "EffLabel" (PVar "n") (PVar "o"))) (EMatch (EVar "o") (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "::"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))) (arm PWild () (EVar "n"))))
(DTypeSig true "builtinLabel" (TyFun (TyCon "String") (TyCon "EffLabel")))
(DFunDef false "builtinLabel" ((PVar "n")) (EApp (EApp (EVar "EffLabel") (EVar "n")) (EVar "OriginBuiltin")))
(DTypeSig true "atomLabel" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "atomLabel" ((PCon "Atom" (PVar "l") PWild)) (EApp (EVar "effLabelName") (EVar "l")))
(DTypeSig true "atomLabelOf" (TyFun (TyCon "Atom") (TyCon "EffLabel")))
(DFunDef false "atomLabelOf" ((PCon "Atom" (PVar "l") PWild)) (EVar "l"))
(DTypeSig true "atomKey" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "atomKey" ((PCon "Atom" (PVar "l") PWild)) (EApp (EVar "labelKey") (EVar "l")))
(DTypeSig true "atomAuth" (TyFun (TyCon "Atom") (TyCon "Authority")))
(DFunDef false "atomAuth" ((PCon "Atom" PWild (PVar "a"))) (EVar "a"))
(DTypeSig true "atomConst" (TyFun (TyCon "Atom") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "atomConst" ((PCon "Atom" PWild (PVar "a"))) (EApp (EVar "authConst") (EVar "a")))
(DTypeSig true "atomBuiltin" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyCon "Atom"))))
(DFunDef false "atomBuiltin" ((PVar "n") (PVar "p")) (EApp (EApp (EVar "Atom") (EApp (EVar "builtinLabel") (EVar "n"))) (EApp (EVar "AConst") (EVar "p"))))
(DTypeSig true "atomWith" (TyFun (TyCon "EffLabel") (TyFun (TyCon "Param") (TyCon "Atom"))))
(DFunDef false "atomWith" ((PVar "l") (PVar "p")) (EApp (EApp (EVar "Atom") (EVar "l")) (EApp (EVar "AConst") (EVar "p"))))
(DTypeSig false "sortKey" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "sortKey" ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "atomKey") (EVar "a")))) (ELit (LString ""))))
(DTypeSig true "renderAtom" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "renderAtom" ((PVar "a")) (EApp (EApp (EVar "renderAtomWith") (EVar "authvarDefaultName")) (EVar "a")))
(DTypeSig true "renderAtomWith" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Atom") (TyCon "String"))))
(DFunDef false "renderAtomWith" ((PVar "name") (PVar "a")) (EMatch (EApp (EVar "authNorm") (EApp (EVar "atomAuth") (EVar "a"))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "name")) (EVar "m"))))) (EVar "ms")))) (arm (PVar "q") () (EBinOp "++" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "name")) (EVar "q"))))))
(DTypeSig true "renderAtoms" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "renderAtoms" ((PVar "atoms")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "renderAtom")) (EApp (EVar "atomsNorm") (EVar "atoms")))))
(DTypeSig true "renderAtomsWith" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "renderAtomsWith" ((PVar "name") (PVar "atoms")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EApp (EVar "renderAtomWith") (EVar "name"))) (EApp (EVar "atomsNorm") (EVar "atoms")))))
(DTypeSig true "atomInsert" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "atomInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "sortKey") (EVar "x"))) (EApp (EVar "sortKey") (EVar "y"))) (arm (PCon "Lt") () (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys")))) (arm (PCon "Eq") () (EBinOp "::" (EApp (EApp (EVar "Atom") (EApp (EVar "atomLabelOf") (EVar "y"))) (EApp (EApp (EVar "authJoin") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (EVar "ys"))) (arm (PCon "Gt") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "atomInsert") (EVar "x")) (EVar "ys"))))))
(DTypeSig true "atomsNorm" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "atomsNorm" ((PList)) (EListLit))
(DFunDef false "atomsNorm" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "atomsNorm" ((PList (PVar "x") (PVar "y"))) (EApp (EApp (EVar "atomInsert") (EVar "y")) (EListLit (EVar "x"))))
(DFunDef false "atomsNorm" ((PList (PVar "x") (PVar "y") (PVar "z"))) (EApp (EApp (EVar "atomInsert") (EVar "z")) (EApp (EApp (EVar "atomInsert") (EVar "y")) (EListLit (EVar "x")))))
(DFunDef false "atomsNorm" ((PVar "xs")) (EApp (EVar "atomsFromIndex") (EApp (EApp (EVar "atomIndex") (EVar "xs")) (EVar "omEmpty"))))
(DTypeSig false "atomIndex" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "OrdMap") (TyCon "Atom")))))
(DFunDef false "atomIndex" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "atomIndex" ((PCons (PVar "x") (PVar "xs")) (PVar "m")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "sortKey") (EVar "x"))) (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "m")) (arm (PCon "None") () (EVar "x")) (arm (PCon "Some" (PVar "old")) () (EApp (EApp (EVar "Atom") (EApp (EVar "atomLabelOf") (EVar "old"))) (EApp (EApp (EVar "authJoin") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "old"))))))) (DoExpr (EApp (EApp (EVar "atomIndex") (EVar "xs")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EVar "next")) (EVar "m"))))))
(DTypeSig false "atomIndexFirst" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "OrdMap") (TyCon "Atom")))))
(DFunDef false "atomIndexFirst" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "atomIndexFirst" ((PCons (PVar "x") (PVar "xs")) (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "sortKey") (EVar "x"))) (EVar "m")) (arm (PCon "None") () (EApp (EApp (EVar "atomIndexFirst") (EVar "xs")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "sortKey") (EVar "x"))) (EVar "x")) (EVar "m")))) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "atomIndexFirst") (EVar "xs")) (EVar "m")))))
(DTypeSig false "atomsFromIndex" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "atomsFromIndex" ((PVar "m")) (EApp (EApp (EVar "atomsFromKeys") (EApp (EVar "omKeys") (EVar "m"))) (EVar "m")))
(DTypeSig false "atomsFromKeys" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsFromKeys" ((PList) PWild) (EListLit))
(DFunDef false "atomsFromKeys" ((PCons (PVar "k") (PVar "ks")) (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "m")) (arm (PCon "Some" (PVar "atom")) () (EBinOp "::" (EVar "atom") (EApp (EApp (EVar "atomsFromKeys") (EVar "ks")) (EVar "m")))) (arm (PCon "None") () (EApp (EApp (EVar "atomsFromKeys") (EVar "ks")) (EVar "m")))))
(DTypeSig true "atomsUnion" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsUnion" ((PVar "a") (PVar "b")) (EApp (EVar "atomsNorm") (EBinOp "++" (EVar "a") (EVar "b"))))
(DTypeSig true "atomsDiff" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiff" ((PList) PWild) (EListLit))
(DFunDef false "atomsDiff" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "atomsDiff" ((PList (PVar "x")) (PVar "ys")) (EApp (EApp (EVar "atomsDiffOne") (EVar "x")) (EVar "ys")))
(DFunDef false "atomsDiff" ((PList (PVar "x") (PVar "y")) (PVar "ys")) (EBinOp "++" (EApp (EApp (EVar "atomsDiffOne") (EVar "x")) (EVar "ys")) (EApp (EApp (EVar "atomsDiffOne") (EVar "y")) (EVar "ys"))))
(DFunDef false "atomsDiff" ((PVar "xs") (PList (PVar "y"))) (EApp (EApp (EVar "atomsDiffOneAgainst") (EVar "xs")) (EVar "y")))
(DFunDef false "atomsDiff" ((PVar "xs") (PVar "ys")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EApp (EApp (EVar "atomIndexFirst") (EVar "ys")) (EVar "omEmpty"))) (EListLit))))
(DTypeSig false "atomsDiffOne" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiffOne" ((PVar "x") (PVar "ys")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomKey") (EVar "x"))) (EVar "ys")) (arm (PCon "None") () (EListLit (EVar "x"))) (arm (PCon "Some" (PVar "y")) () (EIf (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y"))) (EListLit) (EListLit (EVar "x"))))))
(DTypeSig false "atomsDiffOneAgainst" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "Atom") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiffOneAgainst" ((PVar "xs") (PVar "y")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EListLit))))
(DTypeSig false "atomsDiffOneAgainstGo" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsDiffOneAgainstGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "atomsDiffOneAgainstGo" ((PCons (PVar "x") (PVar "xs")) (PVar "y") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomKey") (EVar "x")) (EApp (EVar "atomKey") (EVar "y"))) (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EVar "acc")) (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EBinOp "::" (EVar "x") (EVar "acc")))))
(DTypeSig false "atomsDiffIndexed" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsDiffIndexed" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "atomsDiffIndexed" ((PCons (PVar "x") (PVar "xs")) (PVar "index") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "sortKey") (EVar "x"))) (EVar "index")) (arm (PCon "Some" (PVar "y")) () (EIf (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y"))) (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EVar "index")) (EVar "acc")) (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EVar "index")) (EBinOp "::" (EVar "x") (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EVar "index")) (EBinOp "::" (EVar "x") (EVar "acc"))))))
(DTypeSig true "findAtom" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "Option") (TyCon "Atom")))))
(DFunDef false "findAtom" (PWild (PList)) (EVar "None"))
(DFunDef false "findAtom" ((PVar "k") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "k") (EApp (EVar "atomKey") (EVar "y"))) (EApp (EVar "Some") (EVar "y")) (EApp (EApp (EVar "findAtom") (EVar "k")) (EVar "ys"))))
(DData Public "EffRow" () ((variant "EffRow" (ConPos (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Effvar")))))) ())
(DData Public "Effvar" () ((variant "EUnbound" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "ELink" (ConPos (TyCon "Int") (TyCon "EffRow"))) (variant "EJoin" (ConPos (TyCon "Int") (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (variant "ESummary" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "effrowNorm" (TyFun (TyCon "EffRow") (TyCon "EffRow")))
(DFunDef false "effrowNorm" ((PAs "row" (PCon "EffRow" PWild (PCon "None")))) (EVar "row"))
(DFunDef false "effrowNorm" ((PAs "row" (PCon "EffRow" PWild (PCon "Some" (PVar "cell"))))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" PWild PWild) () (EVar "row")) (arm (PCon "ESummary" PWild PWild PWild) () (EVar "row")) (arm PWild () (EBlock (DoLet false false (PTuple (PVar "labels") (PVar "members")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EMatch (EVar "members") (arm (PList) () (EApp (EApp (EVar "EffRow") (EVar "labels")) (EVar "None"))) (arm (PList (PVar "member")) () (EApp (EApp (EVar "EffRow") (EVar "labels")) (EApp (EVar "Some") (EVar "member")))) (arm PWild () (EApp (EApp (EVar "EffRow") (EVar "labels")) (EApp (EVar "Some") (EApp (EVar "rowRepresentative") (EVar "cell")))))))))))
(DTypeSig false "rowRepresentative" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))
(DFunDef false "rowRepresentative" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ELink" PWild (PCon "EffRow" PWild (PCon "Some" (PVar "next")))) () (EApp (EVar "rowRepresentative") (EVar "next"))) (arm PWild () (EVar "cell"))))
(DTypeSig false "compressLink" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyFun (TyCon "EffRow") (TyCon "EffRow"))))
(DFunDef false "compressLink" ((PVar "cell") (PAs "row" (PCon "EffRow" (PList) (PCon "Some" (PVar "next"))))) (EMatch (EUnOp "!" (EVar "next")) (arm (PCon "ELink" PWild (PAs "nextRow" (PCon "EffRow" (PList) PWild))) () (EBlock (DoLet false false (PVar "target") (EApp (EApp (EVar "compressLink") (EVar "next")) (EVar "nextRow"))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "cell")) (EVar "target"))) (DoExpr (EVar "target")))) (arm PWild () (EVar "row"))))
(DFunDef false "compressLink" (PWild (PVar "row")) (EVar "row"))
(DTypeSig true "effrowLabels" (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "effrowLabels" ((PVar "r")) (EMatch (EApp (EVar "effrowNorm") (EVar "r")) (arm (PCon "EffRow" (PVar "labels") PWild) () (EVar "labels"))))
(DTypeSig true "joinRows" (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "EffRow")))))
(DFunDef false "joinRows" (PWild (PCon "EffRow" (PList) (PCon "None")) (PVar "right")) (EVar "right"))
(DFunDef false "joinRows" (PWild (PVar "left") (PCon "EffRow" (PList) (PCon "None"))) (EVar "left"))
(DFunDef false "joinRows" ((PVar "makeJoin") (PVar "left") (PVar "right")) (EApp (EApp (EVar "collectRows") (EVar "makeJoin")) (EListLit (EVar "left") (EVar "right"))))
(DTypeSig true "collectRows" (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))))
(DFunDef false "collectRows" ((PVar "makeJoin") (PVar "rows")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "cells")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "rows")) (EApp (EApp (EVar "Seen") (EVar "Tip")) (EVar "Tip"))) (EListLit)) (EListLit))) (DoExpr (EMatch (EVar "cells") (arm (PList) () (EApp (EApp (EVar "EffRow") (EVar "atoms")) (EVar "None"))) (arm (PList (PVar "cell")) () (EApp (EApp (EVar "EffRow") (EVar "atoms")) (EApp (EVar "Some") (EVar "cell")))) (arm (PVar "cells") () (EApp (EApp (EVar "EffRow") (EVar "atoms")) (EApp (EVar "Some") (EApp (EVar "makeJoin") (EVar "cells")))))))))
(DTypeSig true "effvarId" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Int")))
(DFunDef false "effvarId" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EVar "id")) (arm (PCon "ELink" (PVar "id") PWild) () (EVar "id")) (arm (PCon "EJoin" (PVar "id") PWild PWild) () (EVar "id")) (arm (PCon "ESummary" (PVar "id") PWild PWild) () (EVar "id"))))
(DTypeSig true "linkRow" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "linkRow" ((PVar "cell") (PVar "row")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ESummary" PWild PWild PWild) () (EApp (EVar "panic") (ELit (LString "effect summary mutated by ordinary row unification")))) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "ELink") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "row"))))))
(DTypeSig true "solveSummaryCell" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "solveSummaryCell" ((PVar "owner") (PVar "cell") (PVar "row")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ESummary" (PVar "id") PWild (PVar "actualOwner")) ((GBool (EBinOp "==" (EVar "owner") (EVar "actualOwner")))) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "ELink") (EVar "id")) (EVar "row")))) (arm PWild () (EApp (EVar "panic") (ELit (LString "effect summary solved outside its owning scope"))))))
(DTypeSig true "rowHasSummary" (TyFun (TyCon "EffRow") (TyCon "Bool")))
(DFunDef false "rowHasSummary" ((PVar "row")) (EApp (EApp (EVar "hasSummaryRows") (EListLit (EVar "row"))) (EVar "Tip")))
(DTypeSig false "hasSummaryRows" (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyCon "Bool"))))
(DFunDef false "hasSummaryRows" ((PList) PWild) (EVar "False"))
(DFunDef false "hasSummaryRows" ((PCons (PCon "EffRow" PWild (PCon "None")) (PVar "rest")) (PVar "seen")) (EApp (EApp (EVar "hasSummaryRows") (EVar "rest")) (EVar "seen")))
(DFunDef false "hasSummaryRows" ((PCons (PCon "EffRow" PWild (PCon "Some" (PVar "cell"))) (PVar "rest")) (PVar "seen")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ESummary" PWild PWild PWild) () (EVar "True")) (arm (PCon "EUnbound" PWild PWild) () (EApp (EApp (EVar "hasSummaryRows") (EVar "rest")) (EVar "seen"))) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EIf (EApp (EApp (EVar "has") (EVar "id")) (EVar "seen")) (EApp (EApp (EVar "hasSummaryRows") (EVar "rest")) (EVar "seen")) (EApp (EApp (EVar "hasSummaryRows") (EBinOp "::" (EVar "row") (EVar "rest"))) (EApp (EApp (EApp (EVar "set") (EVar "id")) (ELit LUnit)) (EVar "seen"))))) (arm (PCon "EJoin" (PVar "id") PWild (PVar "members")) () (EIf (EApp (EApp (EVar "has") (EVar "id")) (EVar "seen")) (EApp (EApp (EVar "hasSummaryRows") (EVar "rest")) (EVar "seen")) (EApp (EApp (EVar "hasSummaryRows") (EApp (EApp (EVar "pushMembers") (EVar "members")) (EVar "rest"))) (EApp (EApp (EApp (EVar "set") (EVar "id")) (ELit LUnit)) (EVar "seen")))))))
(DTypeSig true "isJoinCell" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Bool")))
(DFunDef false "isJoinCell" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EJoin" PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "rowFlat" (TyFun (TyCon "EffRow") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))
(DFunDef false "rowFlat" ((PVar "row")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EListLit (EVar "row"))) (EApp (EApp (EVar "Seen") (EVar "Tip")) (EVar "Tip"))) (EListLit)) (EListLit)))
(DTypeSig true "rowFlatMembers" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "rowFlatMembers" ((PVar "labels") (PVar "members")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EBinOp "::" (EApp (EApp (EVar "EffRow") (EVar "labels")) (EVar "None")) (EApp (EApp (EVar "pushMembers") (EVar "members")) (EListLit)))) (EApp (EApp (EVar "Seen") (EVar "Tip")) (EVar "Tip"))) (EListLit)) (EListLit)))
(DData Private "Seen" () ((variant "Seen" (ConPos (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))) ())
(DTypeSig false "seenUnbound" (TyFun (TyCon "Int") (TyFun (TyCon "Seen") (TyCon "Bool"))))
(DFunDef false "seenUnbound" ((PVar "id") (PCon "Seen" (PVar "unbounds") PWild)) (EApp (EApp (EVar "has") (EVar "id")) (EVar "unbounds")))
(DTypeSig false "seenJoin" (TyFun (TyCon "Int") (TyFun (TyCon "Seen") (TyCon "Bool"))))
(DFunDef false "seenJoin" ((PVar "id") (PCon "Seen" PWild (PVar "joins"))) (EApp (EApp (EVar "has") (EVar "id")) (EVar "joins")))
(DTypeSig false "markUnbound" (TyFun (TyCon "Int") (TyFun (TyCon "Seen") (TyCon "Seen"))))
(DFunDef false "markUnbound" ((PVar "id") (PCon "Seen" (PVar "unbounds") (PVar "joins"))) (EApp (EApp (EVar "Seen") (EApp (EApp (EApp (EVar "set") (EVar "id")) (ELit LUnit)) (EVar "unbounds"))) (EVar "joins")))
(DTypeSig false "markJoin" (TyFun (TyCon "Int") (TyFun (TyCon "Seen") (TyCon "Seen"))))
(DFunDef false "markJoin" ((PVar "id") (PCon "Seen" (PVar "unbounds") (PVar "joins"))) (EApp (EApp (EVar "Seen") (EVar "unbounds")) (EApp (EApp (EApp (EVar "set") (EVar "id")) (ELit LUnit)) (EVar "joins"))))
(DTypeSig false "pushMembers" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyApp (TyCon "List") (TyCon "EffRow")))))
(DFunDef false "pushMembers" ((PVar "members") (PVar "pending")) (EApp (EApp (EVar "pushMembersRev") (EApp (EVar "reverseL") (EVar "members"))) (EVar "pending")))
(DTypeSig false "pushMembersRev" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyApp (TyCon "List") (TyCon "EffRow")))))
(DFunDef false "pushMembersRev" ((PList) (PVar "pending")) (EVar "pending"))
(DFunDef false "pushMembersRev" ((PCons (PVar "member") (PVar "members")) (PVar "pending")) (EApp (EApp (EVar "pushMembersRev") (EVar "members")) (EBinOp "::" (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "member"))) (EVar "pending"))))
(DTypeSig false "addLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "addLabels" ((PList) (PVar "chunks")) (EVar "chunks"))
(DFunDef false "addLabels" ((PVar "labels") (PVar "chunks")) (EBinOp "::" (EVar "labels") (EVar "chunks")))
(DTypeSig false "flattenChunks" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "flattenChunks" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "flattenChunks" ((PCons (PVar "chunk") (PVar "chunks")) (PVar "acc")) (EApp (EApp (EVar "flattenChunks") (EVar "chunks")) (EApp (EApp (EVar "prependChunk") (EVar "chunk")) (EVar "acc"))))
(DTypeSig false "prependChunk" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "prependChunk" ((PVar "chunk") (PVar "acc")) (EApp (EApp (EVar "prependChunkRev") (EApp (EVar "reverseL") (EVar "chunk"))) (EVar "acc")))
(DTypeSig false "prependChunkRev" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "prependChunkRev" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependChunkRev" ((PCons (PVar "atom") (PVar "atoms")) (PVar "acc")) (EApp (EApp (EVar "prependChunkRev") (EVar "atoms")) (EBinOp "::" (EVar "atom") (EVar "acc"))))
(DTypeSig false "rowFlatGo" (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyFun (TyCon "Seen") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))))
(DFunDef false "rowFlatGo" ((PList) PWild (PVar "chunks") (PVar "cells")) (ETuple (EApp (EVar "finishChunks") (EVar "chunks")) (EApp (EVar "reverseL") (EVar "cells"))))
(DFunDef false "rowFlatGo" ((PCons (PCon "EffRow" (PVar "labels") (PVar "tail")) (PVar "pending")) (PVar "seen") (PVar "chunks") (PVar "cells")) (EBlock (DoLet false false PWild (EApp (EVar "opBump") (ELit LUnit))) (DoLet false false (PVar "chunks2") (EApp (EApp (EVar "addLabels") (EVar "labels")) (EVar "chunks"))) (DoExpr (EMatch (EVar "tail") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EVar "seen")) (EVar "chunks2")) (EVar "cells"))) (arm (PCon "Some" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "seenUnbound") (EVar "id")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EVar "seen")) (EVar "chunks2")) (EVar "cells")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EApp (EApp (EVar "markUnbound") (EVar "id")) (EVar "seen"))) (EVar "chunks2")) (EBinOp "::" (EVar "cell") (EVar "cells"))))) (arm (PCon "ESummary" (PVar "id") PWild PWild) () (EIf (EApp (EApp (EVar "seenUnbound") (EVar "id")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EVar "seen")) (EVar "chunks2")) (EVar "cells")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EApp (EApp (EVar "markUnbound") (EVar "id")) (EVar "seen"))) (EVar "chunks2")) (EBinOp "::" (EVar "cell") (EVar "cells"))))) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EIf (EApp (EApp (EVar "seenJoin") (EVar "id")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EVar "seen")) (EVar "chunks2")) (EVar "cells")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EBinOp "::" (EApp (EApp (EVar "compressLink") (EVar "cell")) (EVar "row")) (EVar "pending"))) (EApp (EApp (EVar "markJoin") (EVar "id")) (EVar "seen"))) (EVar "chunks2")) (EVar "cells")))) (arm (PCon "EJoin" (PVar "id") PWild (PVar "members")) () (EIf (EApp (EApp (EVar "seenJoin") (EVar "id")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EVar "seen")) (EVar "chunks2")) (EVar "cells")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EApp (EApp (EVar "pushMembers") (EVar "members")) (EVar "pending"))) (EApp (EApp (EVar "markJoin") (EVar "id")) (EVar "seen"))) (EVar "chunks2")) (EVar "cells"))))))))))
(DTypeSig false "finishChunks" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "finishChunks" ((PList)) (EListLit))
(DFunDef false "finishChunks" ((PList (PVar "labels"))) (EVar "labels"))
(DFunDef false "finishChunks" ((PVar "chunks")) (EApp (EApp (EVar "atomsUnion") (EListLit)) (EApp (EApp (EVar "flattenChunks") (EVar "chunks")) (EListLit))))
(DTypeSig true "dedupCells" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "dedupCells" ((PVar "cells")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "dedupCellsGo") (EVar "cells")) (EVar "Tip")) (EListLit))))
(DTypeSig false "dedupCellsGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "dedupCellsGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "dedupCellsGo" ((PCons (PVar "cell") (PVar "cells")) (PVar "seen") (PVar "acc")) (EBlock (DoLet false false (PVar "id") (EApp (EVar "effvarId") (EVar "cell"))) (DoExpr (EIf (EApp (EApp (EVar "has") (EVar "id")) (EVar "seen")) (EApp (EApp (EApp (EVar "dedupCellsGo") (EVar "cells")) (EVar "seen")) (EVar "acc")) (EApp (EApp (EApp (EVar "dedupCellsGo") (EVar "cells")) (EApp (EApp (EApp (EVar "set") (EVar "id")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EVar "cell") (EVar "acc")))))))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("support" "opcount") ((mem "opBump" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" false) (mem "authJoin" false) (mem "authSub" false) (mem "authConst" false) (mem "renderAuthority" false) (mem "authvarDefaultName" false) (mem "authNorm" false) (mem "renderAuthorityWith" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true))))
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "has" false) (mem "set" false))))
(DData Public "EffLabel" () ((variant "EffLabel" (ConPos (TyCon "String") (TyCon "TyConOrigin")))) ())
(DData Public "Atom" () ((variant "Atom" (ConPos (TyCon "EffLabel") (TyCon "Authority")))) ())
(DTypeSig true "effLabelName" (TyFun (TyCon "EffLabel") (TyCon "String")))
(DFunDef false "effLabelName" ((PCon "EffLabel" (PVar "n") PWild)) (EVar "n"))
(DTypeSig true "effLabelOrigin" (TyFun (TyCon "EffLabel") (TyCon "TyConOrigin")))
(DFunDef false "effLabelOrigin" ((PCon "EffLabel" PWild (PVar "o"))) (EVar "o"))
(DTypeSig true "labelKey" (TyFun (TyCon "EffLabel") (TyCon "String")))
(DFunDef false "labelKey" ((PCon "EffLabel" (PVar "n") (PVar "o"))) (EMatch (EVar "o") (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "::"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))) (arm PWild () (EVar "n"))))
(DTypeSig true "builtinLabel" (TyFun (TyCon "String") (TyCon "EffLabel")))
(DFunDef false "builtinLabel" ((PVar "n")) (EApp (EApp (EVar "EffLabel") (EVar "n")) (EVar "OriginBuiltin")))
(DTypeSig true "atomLabel" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "atomLabel" ((PCon "Atom" (PVar "l") PWild)) (EApp (EVar "effLabelName") (EVar "l")))
(DTypeSig true "atomLabelOf" (TyFun (TyCon "Atom") (TyCon "EffLabel")))
(DFunDef false "atomLabelOf" ((PCon "Atom" (PVar "l") PWild)) (EVar "l"))
(DTypeSig true "atomKey" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "atomKey" ((PCon "Atom" (PVar "l") PWild)) (EApp (EVar "labelKey") (EVar "l")))
(DTypeSig true "atomAuth" (TyFun (TyCon "Atom") (TyCon "Authority")))
(DFunDef false "atomAuth" ((PCon "Atom" PWild (PVar "a"))) (EVar "a"))
(DTypeSig true "atomConst" (TyFun (TyCon "Atom") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "atomConst" ((PCon "Atom" PWild (PVar "a"))) (EApp (EVar "authConst") (EVar "a")))
(DTypeSig true "atomBuiltin" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyCon "Atom"))))
(DFunDef false "atomBuiltin" ((PVar "n") (PVar "p")) (EApp (EApp (EVar "Atom") (EApp (EVar "builtinLabel") (EVar "n"))) (EApp (EVar "AConst") (EVar "p"))))
(DTypeSig true "atomWith" (TyFun (TyCon "EffLabel") (TyFun (TyCon "Param") (TyCon "Atom"))))
(DFunDef false "atomWith" ((PVar "l") (PVar "p")) (EApp (EApp (EVar "Atom") (EVar "l")) (EApp (EVar "AConst") (EVar "p"))))
(DTypeSig false "sortKey" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "sortKey" ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "atomKey") (EVar "a")))) (ELit (LString ""))))
(DTypeSig true "renderAtom" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "renderAtom" ((PVar "a")) (EApp (EApp (EVar "renderAtomWith") (EVar "authvarDefaultName")) (EVar "a")))
(DTypeSig true "renderAtomWith" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyCon "Atom") (TyCon "String"))))
(DFunDef false "renderAtomWith" ((PVar "name") (PVar "a")) (EMatch (EApp (EVar "authNorm") (EApp (EVar "atomAuth") (EVar "a"))) (arm (PCon "AJoin" (PVar "ms")) () (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "name")) (EVar "m"))))) (EVar "ms")))) (arm (PVar "q") () (EBinOp "++" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EApp (EVar "renderAuthorityWith") (EVar "name")) (EVar "q"))))))
(DTypeSig true "renderAtoms" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "renderAtoms" ((PVar "atoms")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "renderAtom")) (EApp (EVar "atomsNorm") (EVar "atoms")))))
(DTypeSig true "renderAtomsWith" (TyFun (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "renderAtomsWith" ((PVar "name") (PVar "atoms")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renderAtomWith") (EVar "name"))) (EApp (EVar "atomsNorm") (EVar "atoms")))))
(DTypeSig true "atomInsert" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "atomInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "sortKey") (EVar "x"))) (EApp (EVar "sortKey") (EVar "y"))) (arm (PCon "Lt") () (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys")))) (arm (PCon "Eq") () (EBinOp "::" (EApp (EApp (EVar "Atom") (EApp (EVar "atomLabelOf") (EVar "y"))) (EApp (EApp (EVar "authJoin") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (EVar "ys"))) (arm (PCon "Gt") () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "atomInsert") (EVar "x")) (EVar "ys"))))))
(DTypeSig true "atomsNorm" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "atomsNorm" ((PList)) (EListLit))
(DFunDef false "atomsNorm" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "atomsNorm" ((PList (PVar "x") (PVar "y"))) (EApp (EApp (EVar "atomInsert") (EVar "y")) (EListLit (EVar "x"))))
(DFunDef false "atomsNorm" ((PList (PVar "x") (PVar "y") (PVar "z"))) (EApp (EApp (EVar "atomInsert") (EVar "z")) (EApp (EApp (EVar "atomInsert") (EVar "y")) (EListLit (EVar "x")))))
(DFunDef false "atomsNorm" ((PVar "xs")) (EApp (EVar "atomsFromIndex") (EApp (EApp (EVar "atomIndex") (EVar "xs")) (EVar "omEmpty"))))
(DTypeSig false "atomIndex" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "OrdMap") (TyCon "Atom")))))
(DFunDef false "atomIndex" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "atomIndex" ((PCons (PVar "x") (PVar "xs")) (PVar "m")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "sortKey") (EVar "x"))) (DoLet false false (PVar "next") (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "m")) (arm (PCon "None") () (EVar "x")) (arm (PCon "Some" (PVar "old")) () (EApp (EApp (EVar "Atom") (EApp (EVar "atomLabelOf") (EVar "old"))) (EApp (EApp (EVar "authJoin") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "old"))))))) (DoExpr (EApp (EApp (EVar "atomIndex") (EVar "xs")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EVar "next")) (EVar "m"))))))
(DTypeSig false "atomIndexFirst" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "OrdMap") (TyCon "Atom")))))
(DFunDef false "atomIndexFirst" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "atomIndexFirst" ((PCons (PVar "x") (PVar "xs")) (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "sortKey") (EVar "x"))) (EVar "m")) (arm (PCon "None") () (EApp (EApp (EVar "atomIndexFirst") (EVar "xs")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "sortKey") (EVar "x"))) (EVar "x")) (EVar "m")))) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "atomIndexFirst") (EVar "xs")) (EVar "m")))))
(DTypeSig false "atomsFromIndex" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "atomsFromIndex" ((PVar "m")) (EApp (EApp (EVar "atomsFromKeys") (EApp (EVar "omKeys") (EVar "m"))) (EVar "m")))
(DTypeSig false "atomsFromKeys" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsFromKeys" ((PList) PWild) (EListLit))
(DFunDef false "atomsFromKeys" ((PCons (PVar "k") (PVar "ks")) (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "m")) (arm (PCon "Some" (PVar "atom")) () (EBinOp "::" (EVar "atom") (EApp (EApp (EVar "atomsFromKeys") (EVar "ks")) (EVar "m")))) (arm (PCon "None") () (EApp (EApp (EVar "atomsFromKeys") (EVar "ks")) (EVar "m")))))
(DTypeSig true "atomsUnion" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsUnion" ((PVar "a") (PVar "b")) (EApp (EVar "atomsNorm") (EBinOp "++" (EVar "a") (EVar "b"))))
(DTypeSig true "atomsDiff" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiff" ((PList) PWild) (EListLit))
(DFunDef false "atomsDiff" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "atomsDiff" ((PList (PVar "x")) (PVar "ys")) (EApp (EApp (EVar "atomsDiffOne") (EVar "x")) (EVar "ys")))
(DFunDef false "atomsDiff" ((PList (PVar "x") (PVar "y")) (PVar "ys")) (EBinOp "++" (EApp (EApp (EVar "atomsDiffOne") (EVar "x")) (EVar "ys")) (EApp (EApp (EVar "atomsDiffOne") (EVar "y")) (EVar "ys"))))
(DFunDef false "atomsDiff" ((PVar "xs") (PList (PVar "y"))) (EApp (EApp (EVar "atomsDiffOneAgainst") (EVar "xs")) (EVar "y")))
(DFunDef false "atomsDiff" ((PVar "xs") (PVar "ys")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EApp (EApp (EVar "atomIndexFirst") (EVar "ys")) (EVar "omEmpty"))) (EListLit))))
(DTypeSig false "atomsDiffOne" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiffOne" ((PVar "x") (PVar "ys")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomKey") (EVar "x"))) (EVar "ys")) (arm (PCon "None") () (EListLit (EVar "x"))) (arm (PCon "Some" (PVar "y")) () (EIf (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y"))) (EListLit) (EListLit (EVar "x"))))))
(DTypeSig false "atomsDiffOneAgainst" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "Atom") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsDiffOneAgainst" ((PVar "xs") (PVar "y")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EListLit))))
(DTypeSig false "atomsDiffOneAgainstGo" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsDiffOneAgainstGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "atomsDiffOneAgainstGo" ((PCons (PVar "x") (PVar "xs")) (PVar "y") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomKey") (EVar "x")) (EApp (EVar "atomKey") (EVar "y"))) (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EVar "acc")) (EApp (EApp (EApp (EVar "atomsDiffOneAgainstGo") (EVar "xs")) (EVar "y")) (EBinOp "::" (EVar "x") (EVar "acc")))))
(DTypeSig false "atomsDiffIndexed" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsDiffIndexed" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "atomsDiffIndexed" ((PCons (PVar "x") (PVar "xs")) (PVar "index") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "sortKey") (EVar "x"))) (EMethodRef "index")) (arm (PCon "Some" (PVar "y")) () (EIf (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y"))) (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EMethodRef "index")) (EVar "acc")) (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EMethodRef "index")) (EBinOp "::" (EVar "x") (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "atomsDiffIndexed") (EVar "xs")) (EMethodRef "index")) (EBinOp "::" (EVar "x") (EVar "acc"))))))
(DTypeSig true "findAtom" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "Option") (TyCon "Atom")))))
(DFunDef false "findAtom" (PWild (PList)) (EVar "None"))
(DFunDef false "findAtom" ((PVar "k") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "k") (EApp (EVar "atomKey") (EVar "y"))) (EApp (EVar "Some") (EVar "y")) (EApp (EApp (EVar "findAtom") (EVar "k")) (EVar "ys"))))
(DData Public "EffRow" () ((variant "EffRow" (ConPos (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Effvar")))))) ())
(DData Public "Effvar" () ((variant "EUnbound" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "ELink" (ConPos (TyCon "Int") (TyCon "EffRow"))) (variant "EJoin" (ConPos (TyCon "Int") (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))))) (variant "ESummary" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "effrowNorm" (TyFun (TyCon "EffRow") (TyCon "EffRow")))
(DFunDef false "effrowNorm" ((PAs "row" (PCon "EffRow" PWild (PCon "None")))) (EVar "row"))
(DFunDef false "effrowNorm" ((PAs "row" (PCon "EffRow" PWild (PCon "Some" (PVar "cell"))))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" PWild PWild) () (EVar "row")) (arm (PCon "ESummary" PWild PWild PWild) () (EVar "row")) (arm PWild () (EBlock (DoLet false false (PTuple (PVar "labels") (PVar "members")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EMatch (EVar "members") (arm (PList) () (EApp (EApp (EVar "EffRow") (EVar "labels")) (EVar "None"))) (arm (PList (PVar "member")) () (EApp (EApp (EVar "EffRow") (EVar "labels")) (EApp (EVar "Some") (EVar "member")))) (arm PWild () (EApp (EApp (EVar "EffRow") (EVar "labels")) (EApp (EVar "Some") (EApp (EVar "rowRepresentative") (EVar "cell")))))))))))
(DTypeSig false "rowRepresentative" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "Ref") (TyCon "Effvar"))))
(DFunDef false "rowRepresentative" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ELink" PWild (PCon "EffRow" PWild (PCon "Some" (PVar "next")))) () (EApp (EVar "rowRepresentative") (EVar "next"))) (arm PWild () (EVar "cell"))))
(DTypeSig false "compressLink" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyFun (TyCon "EffRow") (TyCon "EffRow"))))
(DFunDef false "compressLink" ((PVar "cell") (PAs "row" (PCon "EffRow" (PList) (PCon "Some" (PVar "next"))))) (EMatch (EUnOp "!" (EVar "next")) (arm (PCon "ELink" PWild (PAs "nextRow" (PCon "EffRow" (PList) PWild))) () (EBlock (DoLet false false (PVar "target") (EApp (EApp (EVar "compressLink") (EVar "next")) (EVar "nextRow"))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "cell")) (EVar "target"))) (DoExpr (EVar "target")))) (arm PWild () (EVar "row"))))
(DFunDef false "compressLink" (PWild (PVar "row")) (EVar "row"))
(DTypeSig true "effrowLabels" (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "effrowLabels" ((PVar "r")) (EMatch (EApp (EVar "effrowNorm") (EVar "r")) (arm (PCon "EffRow" (PVar "labels") PWild) () (EVar "labels"))))
(DTypeSig true "joinRows" (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "EffRow")))))
(DFunDef false "joinRows" (PWild (PCon "EffRow" (PList) (PCon "None")) (PVar "right")) (EVar "right"))
(DFunDef false "joinRows" (PWild (PVar "left") (PCon "EffRow" (PList) (PCon "None"))) (EVar "left"))
(DFunDef false "joinRows" ((PVar "makeJoin") (PVar "left") (PVar "right")) (EApp (EApp (EVar "collectRows") (EVar "makeJoin")) (EListLit (EVar "left") (EVar "right"))))
(DTypeSig true "collectRows" (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))))
(DFunDef false "collectRows" ((PVar "makeJoin") (PVar "rows")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "cells")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "rows")) (EApp (EApp (EVar "Seen") (EVar "Tip")) (EVar "Tip"))) (EListLit)) (EListLit))) (DoExpr (EMatch (EVar "cells") (arm (PList) () (EApp (EApp (EVar "EffRow") (EVar "atoms")) (EVar "None"))) (arm (PList (PVar "cell")) () (EApp (EApp (EVar "EffRow") (EVar "atoms")) (EApp (EVar "Some") (EVar "cell")))) (arm (PVar "cells") () (EApp (EApp (EVar "EffRow") (EVar "atoms")) (EApp (EVar "Some") (EApp (EVar "makeJoin") (EVar "cells")))))))))
(DTypeSig true "effvarId" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Int")))
(DFunDef false "effvarId" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EVar "id")) (arm (PCon "ELink" (PVar "id") PWild) () (EVar "id")) (arm (PCon "EJoin" (PVar "id") PWild PWild) () (EVar "id")) (arm (PCon "ESummary" (PVar "id") PWild PWild) () (EVar "id"))))
(DTypeSig true "linkRow" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "linkRow" ((PVar "cell") (PVar "row")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ESummary" PWild PWild PWild) () (EApp (EVar "panic") (ELit (LString "effect summary mutated by ordinary row unification")))) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "ELink") (EApp (EVar "effvarId") (EVar "cell"))) (EVar "row"))))))
(DTypeSig true "solveSummaryCell" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "solveSummaryCell" ((PVar "owner") (PVar "cell") (PVar "row")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ESummary" (PVar "id") PWild (PVar "actualOwner")) ((GBool (EBinOp "==" (EVar "owner") (EVar "actualOwner")))) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "ELink") (EVar "id")) (EVar "row")))) (arm PWild () (EApp (EVar "panic") (ELit (LString "effect summary solved outside its owning scope"))))))
(DTypeSig true "rowHasSummary" (TyFun (TyCon "EffRow") (TyCon "Bool")))
(DFunDef false "rowHasSummary" ((PVar "row")) (EApp (EApp (EVar "hasSummaryRows") (EListLit (EVar "row"))) (EVar "Tip")))
(DTypeSig false "hasSummaryRows" (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyCon "Bool"))))
(DFunDef false "hasSummaryRows" ((PList) PWild) (EVar "False"))
(DFunDef false "hasSummaryRows" ((PCons (PCon "EffRow" PWild (PCon "None")) (PVar "rest")) (PVar "seen")) (EApp (EApp (EVar "hasSummaryRows") (EVar "rest")) (EVar "seen")))
(DFunDef false "hasSummaryRows" ((PCons (PCon "EffRow" PWild (PCon "Some" (PVar "cell"))) (PVar "rest")) (PVar "seen")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ESummary" PWild PWild PWild) () (EVar "True")) (arm (PCon "EUnbound" PWild PWild) () (EApp (EApp (EVar "hasSummaryRows") (EVar "rest")) (EVar "seen"))) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EIf (EApp (EApp (EVar "has") (EVar "id")) (EVar "seen")) (EApp (EApp (EVar "hasSummaryRows") (EVar "rest")) (EVar "seen")) (EApp (EApp (EVar "hasSummaryRows") (EBinOp "::" (EVar "row") (EVar "rest"))) (EApp (EApp (EApp (EVar "set") (EVar "id")) (ELit LUnit)) (EVar "seen"))))) (arm (PCon "EJoin" (PVar "id") PWild (PVar "members")) () (EIf (EApp (EApp (EVar "has") (EVar "id")) (EVar "seen")) (EApp (EApp (EVar "hasSummaryRows") (EVar "rest")) (EVar "seen")) (EApp (EApp (EVar "hasSummaryRows") (EApp (EApp (EVar "pushMembers") (EVar "members")) (EVar "rest"))) (EApp (EApp (EApp (EVar "set") (EVar "id")) (ELit LUnit)) (EVar "seen")))))))
(DTypeSig true "isJoinCell" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Bool")))
(DFunDef false "isJoinCell" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EJoin" PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig true "rowFlat" (TyFun (TyCon "EffRow") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))
(DFunDef false "rowFlat" ((PVar "row")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EListLit (EVar "row"))) (EApp (EApp (EVar "Seen") (EVar "Tip")) (EVar "Tip"))) (EListLit)) (EListLit)))
(DTypeSig true "rowFlatMembers" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "rowFlatMembers" ((PVar "labels") (PVar "members")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EBinOp "::" (EApp (EApp (EVar "EffRow") (EVar "labels")) (EVar "None")) (EApp (EApp (EVar "pushMembers") (EVar "members")) (EListLit)))) (EApp (EApp (EVar "Seen") (EVar "Tip")) (EVar "Tip"))) (EListLit)) (EListLit)))
(DData Private "Seen" () ((variant "Seen" (ConPos (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))))) ())
(DTypeSig false "seenUnbound" (TyFun (TyCon "Int") (TyFun (TyCon "Seen") (TyCon "Bool"))))
(DFunDef false "seenUnbound" ((PVar "id") (PCon "Seen" (PVar "unbounds") PWild)) (EApp (EApp (EVar "has") (EVar "id")) (EVar "unbounds")))
(DTypeSig false "seenJoin" (TyFun (TyCon "Int") (TyFun (TyCon "Seen") (TyCon "Bool"))))
(DFunDef false "seenJoin" ((PVar "id") (PCon "Seen" PWild (PVar "joins"))) (EApp (EApp (EVar "has") (EVar "id")) (EVar "joins")))
(DTypeSig false "markUnbound" (TyFun (TyCon "Int") (TyFun (TyCon "Seen") (TyCon "Seen"))))
(DFunDef false "markUnbound" ((PVar "id") (PCon "Seen" (PVar "unbounds") (PVar "joins"))) (EApp (EApp (EVar "Seen") (EApp (EApp (EApp (EVar "set") (EVar "id")) (ELit LUnit)) (EVar "unbounds"))) (EVar "joins")))
(DTypeSig false "markJoin" (TyFun (TyCon "Int") (TyFun (TyCon "Seen") (TyCon "Seen"))))
(DFunDef false "markJoin" ((PVar "id") (PCon "Seen" (PVar "unbounds") (PVar "joins"))) (EApp (EApp (EVar "Seen") (EVar "unbounds")) (EApp (EApp (EApp (EVar "set") (EVar "id")) (ELit LUnit)) (EVar "joins"))))
(DTypeSig false "pushMembers" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyApp (TyCon "List") (TyCon "EffRow")))))
(DFunDef false "pushMembers" ((PVar "members") (PVar "pending")) (EApp (EApp (EVar "pushMembersRev") (EApp (EVar "reverseL") (EVar "members"))) (EVar "pending")))
(DTypeSig false "pushMembersRev" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyApp (TyCon "List") (TyCon "EffRow")))))
(DFunDef false "pushMembersRev" ((PList) (PVar "pending")) (EVar "pending"))
(DFunDef false "pushMembersRev" ((PCons (PVar "member") (PVar "members")) (PVar "pending")) (EApp (EApp (EVar "pushMembersRev") (EVar "members")) (EBinOp "::" (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "member"))) (EVar "pending"))))
(DTypeSig false "addLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "addLabels" ((PList) (PVar "chunks")) (EVar "chunks"))
(DFunDef false "addLabels" ((PVar "labels") (PVar "chunks")) (EBinOp "::" (EVar "labels") (EVar "chunks")))
(DTypeSig false "flattenChunks" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "flattenChunks" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "flattenChunks" ((PCons (PVar "chunk") (PVar "chunks")) (PVar "acc")) (EApp (EApp (EVar "flattenChunks") (EVar "chunks")) (EApp (EApp (EVar "prependChunk") (EVar "chunk")) (EVar "acc"))))
(DTypeSig false "prependChunk" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "prependChunk" ((PVar "chunk") (PVar "acc")) (EApp (EApp (EVar "prependChunkRev") (EApp (EVar "reverseL") (EVar "chunk"))) (EVar "acc")))
(DTypeSig false "prependChunkRev" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "prependChunkRev" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependChunkRev" ((PCons (PVar "atom") (PVar "atoms")) (PVar "acc")) (EApp (EApp (EVar "prependChunkRev") (EVar "atoms")) (EBinOp "::" (EVar "atom") (EVar "acc"))))
(DTypeSig false "rowFlatGo" (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyFun (TyCon "Seen") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))))
(DFunDef false "rowFlatGo" ((PList) PWild (PVar "chunks") (PVar "cells")) (ETuple (EApp (EVar "finishChunks") (EVar "chunks")) (EApp (EVar "reverseL") (EVar "cells"))))
(DFunDef false "rowFlatGo" ((PCons (PCon "EffRow" (PVar "labels") (PVar "tail")) (PVar "pending")) (PVar "seen") (PVar "chunks") (PVar "cells")) (EBlock (DoLet false false PWild (EApp (EVar "opBump") (ELit LUnit))) (DoLet false false (PVar "chunks2") (EApp (EApp (EVar "addLabels") (EVar "labels")) (EVar "chunks"))) (DoExpr (EMatch (EVar "tail") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EVar "seen")) (EVar "chunks2")) (EVar "cells"))) (arm (PCon "Some" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "seenUnbound") (EVar "id")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EVar "seen")) (EVar "chunks2")) (EVar "cells")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EApp (EApp (EVar "markUnbound") (EVar "id")) (EVar "seen"))) (EVar "chunks2")) (EBinOp "::" (EVar "cell") (EVar "cells"))))) (arm (PCon "ESummary" (PVar "id") PWild PWild) () (EIf (EApp (EApp (EVar "seenUnbound") (EVar "id")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EVar "seen")) (EVar "chunks2")) (EVar "cells")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EApp (EApp (EVar "markUnbound") (EVar "id")) (EVar "seen"))) (EVar "chunks2")) (EBinOp "::" (EVar "cell") (EVar "cells"))))) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EIf (EApp (EApp (EVar "seenJoin") (EVar "id")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EVar "seen")) (EVar "chunks2")) (EVar "cells")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EBinOp "::" (EApp (EApp (EVar "compressLink") (EVar "cell")) (EVar "row")) (EVar "pending"))) (EApp (EApp (EVar "markJoin") (EVar "id")) (EVar "seen"))) (EVar "chunks2")) (EVar "cells")))) (arm (PCon "EJoin" (PVar "id") PWild (PVar "members")) () (EIf (EApp (EApp (EVar "seenJoin") (EVar "id")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EVar "pending")) (EVar "seen")) (EVar "chunks2")) (EVar "cells")) (EApp (EApp (EApp (EApp (EVar "rowFlatGo") (EApp (EApp (EVar "pushMembers") (EVar "members")) (EVar "pending"))) (EApp (EApp (EVar "markJoin") (EVar "id")) (EVar "seen"))) (EVar "chunks2")) (EVar "cells"))))))))))
(DTypeSig false "finishChunks" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "finishChunks" ((PList)) (EListLit))
(DFunDef false "finishChunks" ((PList (PVar "labels"))) (EVar "labels"))
(DFunDef false "finishChunks" ((PVar "chunks")) (EApp (EApp (EVar "atomsUnion") (EListLit)) (EApp (EApp (EVar "flattenChunks") (EVar "chunks")) (EListLit))))
(DTypeSig true "dedupCells" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "dedupCells" ((PVar "cells")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "dedupCellsGo") (EVar "cells")) (EVar "Tip")) (EListLit))))
(DTypeSig false "dedupCellsGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "dedupCellsGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "dedupCellsGo" ((PCons (PVar "cell") (PVar "cells")) (PVar "seen") (PVar "acc")) (EBlock (DoLet false false (PVar "id") (EApp (EVar "effvarId") (EVar "cell"))) (DoExpr (EIf (EApp (EApp (EVar "has") (EVar "id")) (EVar "seen")) (EApp (EApp (EApp (EVar "dedupCellsGo") (EVar "cells")) (EVar "seen")) (EVar "acc")) (EApp (EApp (EApp (EVar "dedupCellsGo") (EVar "cells")) (EApp (EApp (EApp (EVar "set") (EVar "id")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EVar "cell") (EVar "acc")))))))
