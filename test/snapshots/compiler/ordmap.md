# META
source_lines=71
stages=DESUGAR,MARK
# SOURCE
-- `OrdMap a` is a transparent alias for `Map String a` (stdlib/map.mdk).
-- Type-alias expansion now works end-to-end (see
-- `archive/design/TYPE-ALIAS-EXPANSION-DESIGN.md` §10 AS-BUILT), so the old
-- `data OrdMap a = OEmpty | OMap (Map String a)` wrapper is no longer needed.
-- The `om*` helpers below are String-keyed (`omLookup` and `omHasKey` descend
-- the tree with a direct String compare) and are kept for the existing call sites in types/typecheck.mdk, backend/llvm_emit.mdk, and support/util.mdk.

import map.{Map(..), set, size, delete, keys, mapWithKey}

export type OrdMap a = Map String a

export
omEmpty : OrdMap a
omEmpty = Tip

export
omSize : OrdMap a -> Int
omSize m = size m

export
omInsert : String -> a -> OrdMap a -> OrdMap a
omInsert k v m = set k v m

-- Monomorphic String descent: `k < k2` and `k > k2` are the emitter's raw string
-- ordering, so no dictionary-dispatched `compare` and no Ordering value per level.
-- Same visit order and same answer as `get`/`has` on `Map String`.
export
omLookup : String -> OrdMap a -> Option a
omLookup k Tip = None
omLookup k (Bin _ k2 v l r) =
  if k < k2 then omLookup k l else if k > k2 then omLookup k r else Some v

export
omHasKey : String -> OrdMap a -> Bool
omHasKey k Tip = False
omHasKey k (Bin _ k2 _ l r) =
  if k < k2 then omHasKey k l else if k > k2 then omHasKey k r else True

export
omDelete : String -> OrdMap a -> OrdMap a
omDelete k m = delete k m

-- Materialize the key set, sorted ascending. Only for the (rare) sites that
-- need to iterate a whole OrdMap-backed set rather than test membership
-- (e.g. an error-path "did you mean" candidate list) — the O(n) cost is fine
-- there precisely because it is off the hot membership-testing path.
export
omKeys : OrdMap a -> List String
omKeys m = keys m

-- Build a membership set from a name list.
export
omFromNames : List String -> OrdMap Unit -> OrdMap Unit
omFromNames [] m = m
omFromNames (x :: rest) m = omFromNames rest (omInsert x () m)

-- Transform every value in place, preserving the exact tree shape and key set
-- (structural `mapWithKey`, key ignored).  Used to finalise per-key list buckets
-- that were built by prepend — one `reverseL` per bucket restores insert order.
export
omMapValues : (a -> b) -> OrdMap a -> OrdMap b
omMapValues f m = mapWithKey (_ v => f v) m

-- Generic key-value index.  NOTE: when used to memoise an assoc list whose
-- first-match semantics matter, insert the list REVERSED so the first list
-- entry wins on a duplicate key (the caller does the reverse, matching the old
-- `emFromPairs (reverseL t)` convention).
export
omFromPairs : List (String, a) -> OrdMap a -> OrdMap a
omFromPairs [] m = m
omFromPairs ((k, v) :: rest) m = omFromPairs rest (omInsert k v m)
# DESUGAR
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "set" false) (mem "size" false) (mem "delete" false) (mem "keys" false) (mem "mapWithKey" false))))
(DTypeAlias true "OrdMap" ("a") (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyVar "a")))
(DTypeSig true "omEmpty" (TyApp (TyCon "OrdMap") (TyVar "a")))
(DFunDef false "omEmpty" () (EVar "Tip"))
(DTypeSig true "omSize" (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyCon "Int")))
(DFunDef false "omSize" ((PVar "m")) (EApp (EVar "size") (EVar "m")))
(DTypeSig true "omInsert" (TyFun (TyCon "String") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "OrdMap") (TyVar "a"))))))
(DFunDef false "omInsert" ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "m")))
(DTypeSig true "omLookup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "omLookup" ((PVar "k") (PCon "Tip")) (EVar "None"))
(DFunDef false "omLookup" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v") (PVar "l") (PVar "r"))) (EIf (EBinOp "<" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "l")) (EIf (EBinOp ">" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "r")) (EApp (EVar "Some") (EVar "v")))))
(DTypeSig true "omHasKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "omHasKey" ((PVar "k") (PCon "Tip")) (EVar "False"))
(DFunDef false "omHasKey" ((PVar "k") (PCon "Bin" PWild (PVar "k2") PWild (PVar "l") (PVar "r"))) (EIf (EBinOp "<" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "l")) (EIf (EBinOp ">" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "r")) (EVar "True"))))
(DTypeSig true "omDelete" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "OrdMap") (TyVar "a")))))
(DFunDef false "omDelete" ((PVar "k") (PVar "m")) (EApp (EApp (EVar "delete") (EVar "k")) (EVar "m")))
(DTypeSig true "omKeys" (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "omKeys" ((PVar "m")) (EApp (EVar "keys") (EVar "m")))
(DTypeSig true "omFromNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "omFromNames" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "omFromNames" ((PCons (PVar "x") (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "omFromNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "m"))))
(DTypeSig true "omMapValues" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "OrdMap") (TyVar "b")))))
(DFunDef false "omMapValues" ((PVar "f") (PVar "m")) (EApp (EApp (EVar "mapWithKey") (ELam (PWild (PVar "v")) (EApp (EVar "f") (EVar "v")))) (EVar "m")))
(DTypeSig true "omFromPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "OrdMap") (TyVar "a")))))
(DFunDef false "omFromPairs" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "omFromPairs" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "omFromPairs") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EVar "v")) (EVar "m"))))
# MARK
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "set" false) (mem "size" false) (mem "delete" false) (mem "keys" false) (mem "mapWithKey" false))))
(DTypeAlias true "OrdMap" ("a") (TyApp (TyApp (TyCon "Map") (TyCon "String")) (TyVar "a")))
(DTypeSig true "omEmpty" (TyApp (TyCon "OrdMap") (TyVar "a")))
(DFunDef false "omEmpty" () (EVar "Tip"))
(DTypeSig true "omSize" (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyCon "Int")))
(DFunDef false "omSize" ((PVar "m")) (EApp (EVar "size") (EVar "m")))
(DTypeSig true "omInsert" (TyFun (TyCon "String") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "OrdMap") (TyVar "a"))))))
(DFunDef false "omInsert" ((PVar "k") (PVar "v") (PVar "m")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "m")))
(DTypeSig true "omLookup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "omLookup" ((PVar "k") (PCon "Tip")) (EVar "None"))
(DFunDef false "omLookup" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v") (PVar "l") (PVar "r"))) (EIf (EBinOp "<" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "l")) (EIf (EBinOp ">" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "r")) (EApp (EVar "Some") (EVar "v")))))
(DTypeSig true "omHasKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "omHasKey" ((PVar "k") (PCon "Tip")) (EVar "False"))
(DFunDef false "omHasKey" ((PVar "k") (PCon "Bin" PWild (PVar "k2") PWild (PVar "l") (PVar "r"))) (EIf (EBinOp "<" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "l")) (EIf (EBinOp ">" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "r")) (EVar "True"))))
(DTypeSig true "omDelete" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "OrdMap") (TyVar "a")))))
(DFunDef false "omDelete" ((PVar "k") (PVar "m")) (EApp (EApp (EVar "delete") (EVar "k")) (EVar "m")))
(DTypeSig true "omKeys" (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "omKeys" ((PVar "m")) (EApp (EVar "keys") (EVar "m")))
(DTypeSig true "omFromNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "omFromNames" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "omFromNames" ((PCons (PVar "x") (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "omFromNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "m"))))
(DTypeSig true "omMapValues" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "OrdMap") (TyVar "b")))))
(DFunDef false "omMapValues" ((PVar "f") (PVar "m")) (EApp (EApp (EVar "mapWithKey") (ELam (PWild (PVar "v")) (EApp (EVar "f") (EVar "v")))) (EVar "m")))
(DTypeSig true "omFromPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyApp (TyCon "OrdMap") (TyVar "a")))))
(DFunDef false "omFromPairs" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "omFromPairs" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "omFromPairs") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EVar "v")) (EVar "m"))))
