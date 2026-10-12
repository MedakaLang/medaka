# META
source_lines=345
stages=DESUGAR,MARK
# SOURCE
-- compiler/types/effect_policy.mdk — does an entry's invocation summary fit a
-- policy?  A policy is a list of (label, written parameter) entries, the shape
-- a target profile's rows carry.  The verdict (`policyRefusals`) is decided
-- from the atoms and the grants alone; the call-chain explanation
-- (`viaChain`) is a separate entry point, called only on a refusal.
import frontend.ast.{
  EffParamTy(..),
  TyConOrigin(..),
  Decl(..),
  Expr(..),
  Arm(..),
  Guard(..),
  DoStmt(..),
  LetBind(..),
  FunClause(..),
  FieldAssign(..),
}
import types.effect_authority.{
  Authority(..), authSub, authVars, authHasVars, authvarDefaultName, authJoinAll
}
import types.effect_rows.{
  effLabelOrigin,
  atomLabelOf,
  atomLabel,
  atomAuth,
  atomsUnion,
  renderAtom,
  Atom(..),
  effrowLabels,
}
import types.repr.{Scheme(..), Mono(..), normalize}
import types.typecheck.{decodeWrittenParam, atomOfLabel}
import types.target_profile.{hostLabels}
import support.util.{
  sortUniqS, joinWith, reverseL, filterList, contains, anyList
}
import support.ordmap.{
  OrdMap, omEmpty, omFromPairs, omFromNames, omLookup, omHasKey
}

-- ── the verdict ─────────────────────────────────────────────────────────────
-- Admitted, or refused with the labels of the refused atoms (in atom order) and
-- the report lines that explain them: each malformed entry's problem, then each
-- unresolved authority that a narrower grant could not be proven to cover.
public export data PolicyVerdict =
  | PolicyAdmitted
  | PolicyRefused (List String) (List String)

-- The one call: the atoms an entry may perform against a policy.  The
-- explanation lines are built only on a refusal.
export
policyRefusals : List Atom -> List (String, EffParamTy) -> PolicyVerdict
policyRefusals atoms policy = match filterForbidden atoms policy
  [] => PolicyAdmitted
  labels =>
    PolicyRefused
      labels
      (policyProblems atoms policy ++ notProvenLines atoms policy)

filterForbidden : List Atom -> List (String, EffParamTy) -> List String
filterForbidden [] _ = []
filterForbidden (a :: rest) policy = match permitOf a policy
  Permitted => filterForbidden rest policy
  _ => atomLabel a :: filterForbidden rest policy

-- Why each refused atom's policy entry could not be read, one report line per
-- malformed entry the verdict met.
policyProblems : List Atom -> List (String, EffParamTy) -> List String
policyProblems effs policy =
  flatMap
    (a => match permitOf a policy
      Malformed m => ["   policy entry for \{atomLabel a}: \{m}\n"]
      _ => [])
    effs

export data Permit = Permitted | Forbidden | Malformed String

-- Permitted iff the label is in the policy AND the inferred authority is
-- provably within what the label's entries admit together, each entry decoded
-- in the domain of the atom's own label: an authority still symbolic at the
-- manifest boundary is not proven and is not permitted, and an entry the
-- domain does not admit permits nothing.
export
permitOf : Atom -> List (String, EffParamTy) -> Permit
permitOf a policy = match (atomLabel a == "IO", policyEntriesFor a policy)
  (True, []) => permitIoAsJoin policy
  (_, []) => Forbidden
  (_, written) => match allOk (map (decodeWrittenParam (atomLabelOf a)) written)
    -- The entries are read exactly, however many there are: a set is never
    -- folded, so a manifest of any size is accepted back as a policy.
    Ok pps =>
      if authSub (atomAuth a) (authJoinAll (map AConst pps)) then
        Permitted
      else
        Forbidden
    Err m => Malformed m

-- Here `IO` is the join of the eleven host labels, so an `IO` atom under a
-- policy with no `IO` entry is permitted exactly when the policy admits every
-- one of the eleven at its top.  That is `IO`'s meaning with no profile, which
-- is `check-policy`'s case: its policy is a manifest, not a profile.  The one
-- caller that passes a profile's grants, `tools.target_check`, never passes an
-- `IO` atom, because the typechecker has already bounded `IO` by that
-- profile's join.
permitIoAsJoin : List (String, EffParamTy) -> Permit
permitIoAsJoin policy =
  firstNotPermitted (map (l => permitOf (atomOfLabel l) policy) hostLabels)

firstNotPermitted : List Permit -> Permit
firstNotPermitted [] = Permitted
firstNotPermitted (Permitted :: rest) = firstNotPermitted rest
firstNotPermitted (p :: _) = p

-- An atom whose authority is still a variable at the host boundary, refused
-- by a policy entry narrower than the whole label: the entry may well cover
-- what the caller will choose, but nothing proves it.
notProvenLines : List Atom -> List (String, EffParamTy) -> List String
notProvenLines effs policy =
  flatMap
    (a => match (authHasVars (atomAuth a), permitOf a policy)
      (True, Forbidden) => match policyEntriesFor a policy
        _ :: _ =>
          let unresolved =
            Atom
              (atomLabelOf a)
              (authJoinAll (map AVar (authVars (atomAuth a))))
          ["   not proven: \{renderAtom unresolved} (\{unresolvedWhy a})\n"]
        [] => []
      _ => [])
    effs

-- Why an atom's authority is unresolved: the variables it still names.
export
unresolvedWhy : Atom -> String
unresolvedWhy a =
  let names =
    map (v => "`" ++ authvarDefaultName v ++ "`") (authVars (atomAuth a))
  match names
    [one] => "authority variable \{one}"
    _ => "authority variables \{joinWith ", " names}"

-- The entries for an atom: those under its qualified key, else those under
-- its bare label.
policyEntriesFor : Atom -> List (String, EffParamTy) -> List EffParamTy
policyEntriesFor a policy =
  match entriesUnder (policySpelling (qualifiedKey a)) policy
    [] => entriesUnder (atomLabel a) policy
    es => es

entriesUnder : String -> List (String, EffParamTy) -> List EffParamTy
entriesUnder key policy = map snd (filterList (e => fst e == key) policy)

-- A policy token spells a qualified key without the TOML quotes.
policySpelling : String -> String
policySpelling k =
  let n = stringLength k
  if n >= 2 && stringSlice 0 1 k == "\"" && stringSlice (n - 1) n k == "\"" then
    stringSlice 1 (n - 1) k
  else
    k

-- `"mod.Name"` for a module-declared label, the bare name for a builtin.
export
qualifiedKey : Atom -> String
qualifiedKey a = match effLabelOrigin (atomLabelOf a)
  OriginModule m => "\"\{m}.\{atomLabel a}\""
  _ => atomLabel a

-- Every result's value, or the first error.
export
allOk : List (Result String a) -> Result String (List a)
allOk [] = Ok []
allOk ((Err m) :: _) = Err m
allOk ((Ok x) :: rest) = map (x :: _) (allOk rest)

-- ── the call graph ──────────────────────────────────────────────────────────
-- name → callees restricted to top-level names.  Keyed; on a repeated name the
-- first binding wins, as a first-match scan would.
export type CallGraph = OrdMap (List String)

-- name → the atoms calling it performs, for every effectful fn.
export type EffectTable = OrdMap (List Atom)

-- collectEVars: every EVar name referenced in an expression (conservative —
-- includes non-call uses, safe for the chain heuristic).  The desugared tree
-- has no EGuards/ESection/EBlock surface sugar, so those arms are omitted
-- (already lowered).
collectEVars : Expr -> List String
collectEVars (EVar n) = [n]
collectEVars (ELoc _ e) = collectEVars e
collectEVars (EMethodRef n) = [n]
collectEVars (EDictApp n) = [n]
collectEVars (EApp f x) = collectEVars f ++ collectEVars x
collectEVars (ELam _ body) = collectEVars body
collectEVars (ELet _ _ _ v body) = collectEVars v ++ collectEVars body
collectEVars (ELetGroup binds body) =
  concatMapCP collectBind binds ++ collectEVars body
collectEVars (EMatch e arms) = collectEVars e ++ concatMapCP collectArm arms
collectEVars (EIf c t f) = collectEVars c ++ collectEVars t ++ collectEVars f
collectEVars (EBinOp _ a b _) = collectEVars a ++ collectEVars b
collectEVars (EUnOp _ e _) = collectEVars e
collectEVars (EInfix _ a b) = collectEVars a ++ collectEVars b
collectEVars (EAnnot e _) = collectEVars e
collectEVars (EHeadAnnot e _) = collectEVars e
collectEVars (EFieldAccess e _ _) = collectEVars e
collectEVars (ERecordCreate _ flds) = concatMapCP collectFieldAssign flds
collectEVars (ERecordUpdate e flds _) =
  collectEVars e ++ concatMapCP collectFieldAssign flds
collectEVars (EVariantUpdate _ e flds) =
  collectEVars e ++ concatMapCP collectFieldAssign flds
collectEVars (ETuple es) = concatMapCP collectEVars es
collectEVars (EListLit es) = concatMapCP collectEVars es
collectEVars (EArrayLit es) = concatMapCP collectEVars es
collectEVars (ERangeList a b _) = collectEVars a ++ collectEVars b
collectEVars (ERangeArray a b _) = collectEVars a ++ collectEVars b
collectEVars (ESlice a b c _ _) =
  collectEVars a ++ collectEVars b ++ collectEVars c
collectEVars (EIndex a b _) = collectEVars a ++ collectEVars b
collectEVars (EBlock stmts) = concatMapCP collectStmt stmts
collectEVars (EDo _ stmts) = concatMapCP collectStmt stmts
collectEVars _ = []

collectBind : LetBind -> List String
collectBind (LetBind _ clauses _) = concatMapCP collectClause clauses

collectClause : FunClause -> List String
collectClause (FunClause _ body) = collectEVars body

collectArm : Arm -> List String
collectArm (Arm _ guards body) =
  concatMapCP collectGuard guards ++ collectEVars body

collectGuard : Guard -> List String
collectGuard (GBool e) = collectEVars e
collectGuard (GBind _ e) = collectEVars e

collectFieldAssign : FieldAssign -> List String
collectFieldAssign (FieldAssign _ e) = collectEVars e

collectStmt : DoStmt -> List String
collectStmt (DoExpr e) = collectEVars e
collectStmt (DoBind _ e) = collectEVars e
collectStmt (DoLet _ _ _ e _) = collectEVars e
collectStmt (DoAssign _ e) = collectEVars e
collectStmt (DoFieldAssign _ _ e) = collectEVars e

concatMapCP : (a -> List b) -> List a -> List b
concatMapCP _ [] = []
concatMapCP f (x :: xs) = f x ++ concatMapCP f xs

-- A top-level name (DFunDef or DExtern), peeling DAttrib.
topName : Decl -> Option String
topName (DFunDef _ n _ _ _) = Some n
topName (DExtern _ n _) = Some n
topName (DAttrib _ d) = topName d
topName _ = None

-- (name, body-EVars) for each top-level DFunDef (externs have no body).
fnBody : Decl -> Option (String, List String)
fnBody (DFunDef _ n _ body _) = Some (n, collectEVars body)
fnBody (DAttrib _ d) = fnBody d
fnBody _ = None

export
buildCallGraph : List Decl -> CallGraph
buildCallGraph decls =
  let tops = omFromNames (collectOpts (map topName decls)) omEmpty
  let bodies = collectOpts (map fnBody decls)
  omFromPairs (reverseL (map (restrictBody tops) bodies)) omEmpty

restrictBody : OrdMap Unit -> (String, List String) -> (String, List String)
restrictBody tops (n, refs) = (n, filterList (r => omHasKey r tops) refs)

collectOpts : List (Option a) -> List a
collectOpts [] = []
collectOpts (None :: rest) = collectOpts rest
collectOpts ((Some x) :: rest) = x :: collectOpts rest

-- ── effectful callees ───────────────────────────────────────────────────────
-- (name, effect-atoms) for every fn whose CALL performs a non-empty effect set:
-- the chain below follows what calling a callee performs, not what a host
-- could reach through it.
export
fnEffectsTable : List (String, Scheme) -> EffectTable
fnEffectsTable schemes = omFromPairs (reverseL (effectfulPairs schemes)) omEmpty

effectfulPairs : List (String, Scheme) -> List (String, List Atom)
effectfulPairs [] = []
effectfulPairs ((name, sch) :: rest) = match callPerformed sch
  [] => effectfulPairs rest
  effs => (name, effs) :: effectfulPairs rest

-- What applying a binding performs: its forcing row and the rows along its
-- result spine, an effect index returned included.
callPerformed : Scheme -> List Atom
callPerformed (Forall _ _ _ _ force mono) =
  atomsUnion (effrowLabels force) (resultSpineRows mono)

resultSpineRows : Mono -> List Atom
resultSpineRows m = match normalize m
  TFun _ row res => atomsUnion (effrowLabels row) (resultSpineRows res)
  TEff row => effrowLabels row
  _ => []

-- Does fn `name` carry an atom whose LABEL is `label`?  (Chain reconstruction
-- stays label-keyed — the param does not participate in the call-graph trace.)
fnHasEffect : EffectTable -> String -> String -> Bool
fnHasEffect table name label = match omLookup name table
  None => False
  Some effs => anyList (a => atomLabel a == label) effs

-- ── the via-chain ───────────────────────────────────────────────────────────
-- From `start`, repeatedly hop to the lexicographically-smallest callee that
-- carries `forbiddenLabel`, stopping at a leaf or a revisit.  Called only to
-- explain a refusal.
export
viaChain : CallGraph -> EffectTable -> String -> String -> List String
viaChain callGraph effTable start forbiddenLabel =
  traceChain callGraph effTable forbiddenLabel start [start]

traceChain : CallGraph ->
  EffectTable ->
  String ->
  String ->
  List String ->
  List String
traceChain callGraph effTable forbiddenLabel fn visited =
  let callees = match omLookup fn callGraph
    None => []
    Some s => s
  match firstWithEffect effTable forbiddenLabel (sortUniqS callees)
    None => [fn]
    Some c =>
      if contains c visited then
        [fn, c]
      else
        fn :: traceChain callGraph effTable forbiddenLabel c (c :: visited)

firstWithEffect : EffectTable -> String -> List String -> Option String
firstWithEffect _ _ [] = None
firstWithEffect effTable label (c :: rest) =
  if fnHasEffect effTable c label then
    Some c
  else
    firstWithEffect effTable label rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true) (mem "TyConOrigin" true) (mem "Decl" true) (mem "Expr" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "LetBind" true) (mem "FunClause" true) (mem "FieldAssign" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "authSub" false) (mem "authVars" false) (mem "authHasVars" false) (mem "authvarDefaultName" false) (mem "authJoinAll" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "effLabelOrigin" false) (mem "atomLabelOf" false) (mem "atomLabel" false) (mem "atomAuth" false) (mem "atomsUnion" false) (mem "renderAtom" false) (mem "Atom" true) (mem "effrowLabels" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "decodeWrittenParam" false) (mem "atomOfLabel" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "hostLabels" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "joinWith" false) (mem "reverseL" false) (mem "filterList" false) (mem "contains" false) (mem "anyList" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omLookup" false) (mem "omHasKey" false))))
(DData Public "PolicyVerdict" () ((variant "PolicyAdmitted" (ConPos)) (variant "PolicyRefused" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig true "policyRefusals" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "PolicyVerdict"))))
(DFunDef false "policyRefusals" ((PVar "atoms") (PVar "policy")) (EMatch (EApp (EApp (EVar "filterForbidden") (EVar "atoms")) (EVar "policy")) (arm (PList) () (EVar "PolicyAdmitted")) (arm (PVar "labels") () (EApp (EApp (EVar "PolicyRefused") (EVar "labels")) (EBinOp "++" (EApp (EApp (EVar "policyProblems") (EVar "atoms")) (EVar "policy")) (EApp (EApp (EVar "notProvenLines") (EVar "atoms")) (EVar "policy")))))))
(DTypeSig false "filterForbidden" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterForbidden" ((PList) PWild) (EListLit))
(DFunDef false "filterForbidden" ((PCons (PVar "a") (PVar "rest")) (PVar "policy")) (EMatch (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy")) (arm (PCon "Permitted") () (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy"))) (arm PWild () (EBinOp "::" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy"))))))
(DTypeSig false "policyProblems" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "policyProblems" ((PVar "effs") (PVar "policy")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "a")) (EMatch (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy")) (arm (PCon "Malformed" (PVar "m")) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   policy entry for ")) (EApp (EVar "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))))) (arm PWild () (EListLit))))) (EVar "effs")))
(DData Abstract "Permit" () ((variant "Permitted" (ConPos)) (variant "Forbidden" (ConPos)) (variant "Malformed" (ConPos (TyCon "String")))) ())
(DTypeSig true "permitOf" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit"))))
(DFunDef false "permitOf" ((PVar "a") (PVar "policy")) (EMatch (ETuple (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (ELit (LString "IO"))) (EApp (EApp (EVar "policyEntriesFor") (EVar "a")) (EVar "policy"))) (arm (PTuple (PCon "True") (PList)) () (EApp (EVar "permitIoAsJoin") (EVar "policy"))) (arm (PTuple PWild (PList)) () (EVar "Forbidden")) (arm (PTuple PWild (PVar "written")) () (EMatch (EApp (EVar "allOk") (EApp (EApp (EVar "map") (EApp (EVar "decodeWrittenParam") (EApp (EVar "atomLabelOf") (EVar "a")))) (EVar "written"))) (arm (PCon "Ok" (PVar "pps")) () (EIf (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "a"))) (EApp (EVar "authJoinAll") (EApp (EApp (EVar "map") (EVar "AConst")) (EVar "pps")))) (EVar "Permitted") (EVar "Forbidden"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Malformed") (EVar "m")))))))
(DTypeSig false "permitIoAsJoin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit")))
(DFunDef false "permitIoAsJoin" ((PVar "policy")) (EApp (EVar "firstNotPermitted") (EApp (EApp (EVar "map") (ELam ((PVar "l")) (EApp (EApp (EVar "permitOf") (EApp (EVar "atomOfLabel") (EVar "l"))) (EVar "policy")))) (EVar "hostLabels"))))
(DTypeSig false "firstNotPermitted" (TyFun (TyApp (TyCon "List") (TyCon "Permit")) (TyCon "Permit")))
(DFunDef false "firstNotPermitted" ((PList)) (EVar "Permitted"))
(DFunDef false "firstNotPermitted" ((PCons (PCon "Permitted") (PVar "rest"))) (EApp (EVar "firstNotPermitted") (EVar "rest")))
(DFunDef false "firstNotPermitted" ((PCons (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "notProvenLines" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "notProvenLines" ((PVar "effs") (PVar "policy")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "a")) (EMatch (ETuple (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a"))) (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy"))) (arm (PTuple (PCon "True") (PCon "Forbidden")) () (EMatch (EApp (EApp (EVar "policyEntriesFor") (EVar "a")) (EVar "policy")) (arm (PCons PWild PWild) () (EBlock (DoLet false false (PVar "unresolved") (EApp (EApp (EVar "Atom") (EApp (EVar "atomLabelOf") (EVar "a"))) (EApp (EVar "authJoinAll") (EApp (EApp (EVar "map") (EVar "AVar")) (EApp (EVar "authVars") (EApp (EVar "atomAuth") (EVar "a"))))))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   not proven: ")) (EApp (EVar "display") (EApp (EVar "renderAtom") (EVar "unresolved")))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EVar "unresolvedWhy") (EVar "a")))) (ELit (LString ")\n"))))))) (arm (PList) () (EListLit)))) (arm PWild () (EListLit))))) (EVar "effs")))
(DTypeSig true "unresolvedWhy" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "unresolvedWhy" ((PVar "a")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "authvarDefaultName") (EVar "v"))) (ELit (LString "`"))))) (EApp (EVar "authVars") (EApp (EVar "atomAuth") (EVar "a"))))) (DoExpr (EMatch (EVar "names") (arm (PList (PVar "one")) () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variable ")) (EApp (EVar "display") (EVar "one"))) (ELit (LString "")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variables ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "names")))) (ELit (LString ""))))))))
(DTypeSig false "policyEntriesFor" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "policyEntriesFor" ((PVar "a") (PVar "policy")) (EMatch (EApp (EApp (EVar "entriesUnder") (EApp (EVar "policySpelling") (EApp (EVar "qualifiedKey") (EVar "a")))) (EVar "policy")) (arm (PList) () (EApp (EApp (EVar "entriesUnder") (EApp (EVar "atomLabel") (EVar "a"))) (EVar "policy"))) (arm (PVar "es") () (EVar "es"))))
(DTypeSig false "entriesUnder" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "entriesUnder" ((PVar "key") (PVar "policy")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "fst") (EVar "e")) (EVar "key")))) (EVar "policy"))))
(DTypeSig false "policySpelling" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "policySpelling" ((PVar "k")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "k"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "k")) (ELit (LString "\"")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "k")) (ELit (LString "\"")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "k")) (EVar "k")))))
(DTypeSig true "qualifiedKey" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "qualifiedKey" ((PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString "\"")))) (arm PWild () (EApp (EVar "atomLabel") (EVar "a")))))
(DTypeSig true "allOk" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "allOk" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "allOk" ((PCons (PCon "Err" (PVar "m")) PWild)) (EApp (EVar "Err") (EVar "m")))
(DFunDef false "allOk" ((PCons (PCon "Ok" (PVar "x")) (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "allOk") (EVar "rest"))))
(DTypeAlias true "CallGraph" () (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))
(DTypeAlias true "EffectTable" () (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Atom"))))
(DTypeSig false "collectEVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectEVars" ((PCon "EVar" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EMethodRef" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EDictApp" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "f")) (EApp (EVar "collectEVars") (EVar "x"))))
(DFunDef false "collectEVars" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DFunDef false "collectEVars" ((PCon "ELet" PWild PWild PWild (PVar "v") (PVar "body"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "v")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectBind")) (EVar "binds")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectArm")) (EVar "arms"))))
(DFunDef false "collectEVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "c")) (EApp (EVar "collectEVars") (EVar "t"))) (EApp (EVar "collectEVars") (EVar "f"))))
(DFunDef false "collectEVars" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "ERecordCreate" PWild (PVar "flds"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds")))
(DFunDef false "collectEVars" ((PCon "ERecordUpdate" (PVar "e") (PVar "flds") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "flds"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ESlice" (PVar "a") (PVar "b") (PVar "c") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))) (EApp (EVar "collectEVars") (EVar "c"))))
(DFunDef false "collectEVars" ((PCon "EIndex" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" (PWild) (EListLit))
(DTypeSig false "collectBind" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectBind" ((PCon "LetBind" PWild (PVar "clauses") PWild)) (EApp (EApp (EVar "concatMapCP") (EVar "collectClause")) (EVar "clauses")))
(DTypeSig false "collectClause" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectClause" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DTypeSig false "collectArm" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectArm" ((PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectGuard")) (EVar "guards")) (EApp (EVar "collectEVars") (EVar "body"))))
(DTypeSig false "collectGuard" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectGuard" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectFieldAssign" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectFieldAssign" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectStmt" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "concatMapCP" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapCP" (PWild (PList)) (EListLit))
(DFunDef false "concatMapCP" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapCP") (EVar "f")) (EVar "xs"))))
(DTypeSig false "topName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "topName" ((PCon "DFunDef" PWild (PVar "n") PWild PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DExtern" PWild (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topName") (EVar "d")))
(DFunDef false "topName" (PWild) (EVar "None"))
(DTypeSig false "fnBody" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fnBody" ((PCon "DFunDef" PWild (PVar "n") PWild (PVar "body") PWild)) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "collectEVars") (EVar "body")))))
(DFunDef false "fnBody" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "fnBody") (EVar "d")))
(DFunDef false "fnBody" (PWild) (EVar "None"))
(DTypeSig true "buildCallGraph" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CallGraph")))
(DFunDef false "buildCallGraph" ((PVar "decls")) (EBlock (DoLet false false (PVar "tops") (EApp (EApp (EVar "omFromNames") (EApp (EVar "collectOpts") (EApp (EApp (EVar "map") (EVar "topName")) (EVar "decls")))) (EVar "omEmpty"))) (DoLet false false (PVar "bodies") (EApp (EVar "collectOpts") (EApp (EApp (EVar "map") (EVar "fnBody")) (EVar "decls")))) (DoExpr (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (EApp (EVar "restrictBody") (EVar "tops"))) (EVar "bodies")))) (EVar "omEmpty")))))
(DTypeSig false "restrictBody" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "restrictBody" ((PVar "tops") (PTuple (PVar "n") (PVar "refs"))) (ETuple (EVar "n") (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EVar "r")) (EVar "tops")))) (EVar "refs"))))
(DTypeSig false "collectOpts" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "collectOpts" ((PList)) (EListLit))
(DFunDef false "collectOpts" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "collectOpts") (EVar "rest")))
(DFunDef false "collectOpts" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "collectOpts") (EVar "rest"))))
(DTypeSig true "fnEffectsTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "EffectTable")))
(DFunDef false "fnEffectsTable" ((PVar "schemes")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "effectfulPairs") (EVar "schemes")))) (EVar "omEmpty")))
(DTypeSig false "effectfulPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "effectfulPairs" ((PList)) (EListLit))
(DFunDef false "effectfulPairs" ((PCons (PTuple (PVar "name") (PVar "sch")) (PVar "rest"))) (EMatch (EApp (EVar "callPerformed") (EVar "sch")) (arm (PList) () (EApp (EVar "effectfulPairs") (EVar "rest"))) (arm (PVar "effs") () (EBinOp "::" (ETuple (EVar "name") (EVar "effs")) (EApp (EVar "effectfulPairs") (EVar "rest"))))))
(DTypeSig false "callPerformed" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "callPerformed" ((PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "mono"))) (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "force"))) (EApp (EVar "resultSpineRows") (EVar "mono"))))
(DTypeSig false "resultSpineRows" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "resultSpineRows" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild (PVar "row") (PVar "res")) () (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "row"))) (EApp (EVar "resultSpineRows") (EVar "res")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EVar "effrowLabels") (EVar "row"))) (arm PWild () (EListLit))))
(DTypeSig false "fnHasEffect" (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "fnHasEffect" ((PVar "table") (PVar "name") (PVar "label")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "table")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "effs")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (EVar "label")))) (EVar "effs")))))
(DTypeSig true "viaChain" (TyFun (TyCon "CallGraph") (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "viaChain" ((PVar "callGraph") (PVar "effTable") (PVar "start") (PVar "forbiddenLabel")) (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "start")) (EListLit (EVar "start"))))
(DTypeSig false "traceChain" (TyFun (TyCon "CallGraph") (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "traceChain" ((PVar "callGraph") (PVar "effTable") (PVar "forbiddenLabel") (PVar "fn") (PVar "visited")) (EBlock (DoLet false false (PVar "callees") (EMatch (EApp (EApp (EVar "omLookup") (EVar "fn")) (EVar "callGraph")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EVar "s")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "forbiddenLabel")) (EApp (EVar "sortUniqS") (EVar "callees"))) (arm (PCon "None") () (EListLit (EVar "fn"))) (arm (PCon "Some" (PVar "c")) () (EIf (EApp (EApp (EVar "contains") (EVar "c")) (EVar "visited")) (EListLit (EVar "fn") (EVar "c")) (EBinOp "::" (EVar "fn") (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "c")) (EBinOp "::" (EVar "c") (EVar "visited"))))))))))
(DTypeSig false "firstWithEffect" (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstWithEffect" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstWithEffect" ((PVar "effTable") (PVar "label") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "fnHasEffect") (EVar "effTable")) (EVar "c")) (EVar "label")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "label")) (EVar "rest"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true) (mem "TyConOrigin" true) (mem "Decl" true) (mem "Expr" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "LetBind" true) (mem "FunClause" true) (mem "FieldAssign" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "authSub" false) (mem "authVars" false) (mem "authHasVars" false) (mem "authvarDefaultName" false) (mem "authJoinAll" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "effLabelOrigin" false) (mem "atomLabelOf" false) (mem "atomLabel" false) (mem "atomAuth" false) (mem "atomsUnion" false) (mem "renderAtom" false) (mem "Atom" true) (mem "effrowLabels" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "decodeWrittenParam" false) (mem "atomOfLabel" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "hostLabels" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "joinWith" false) (mem "reverseL" false) (mem "filterList" false) (mem "contains" false) (mem "anyList" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omLookup" false) (mem "omHasKey" false))))
(DData Public "PolicyVerdict" () ((variant "PolicyAdmitted" (ConPos)) (variant "PolicyRefused" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig true "policyRefusals" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "PolicyVerdict"))))
(DFunDef false "policyRefusals" ((PVar "atoms") (PVar "policy")) (EMatch (EApp (EApp (EVar "filterForbidden") (EVar "atoms")) (EVar "policy")) (arm (PList) () (EVar "PolicyAdmitted")) (arm (PVar "labels") () (EApp (EApp (EVar "PolicyRefused") (EVar "labels")) (EBinOp "++" (EApp (EApp (EVar "policyProblems") (EVar "atoms")) (EVar "policy")) (EApp (EApp (EVar "notProvenLines") (EVar "atoms")) (EVar "policy")))))))
(DTypeSig false "filterForbidden" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterForbidden" ((PList) PWild) (EListLit))
(DFunDef false "filterForbidden" ((PCons (PVar "a") (PVar "rest")) (PVar "policy")) (EMatch (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy")) (arm (PCon "Permitted") () (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy"))) (arm PWild () (EBinOp "::" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy"))))))
(DTypeSig false "policyProblems" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "policyProblems" ((PVar "effs") (PVar "policy")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "a")) (EMatch (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy")) (arm (PCon "Malformed" (PVar "m")) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   policy entry for ")) (EApp (EMethodRef "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))))) (arm PWild () (EListLit))))) (EVar "effs")))
(DData Abstract "Permit" () ((variant "Permitted" (ConPos)) (variant "Forbidden" (ConPos)) (variant "Malformed" (ConPos (TyCon "String")))) ())
(DTypeSig true "permitOf" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit"))))
(DFunDef false "permitOf" ((PVar "a") (PVar "policy")) (EMatch (ETuple (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (ELit (LString "IO"))) (EApp (EApp (EVar "policyEntriesFor") (EVar "a")) (EVar "policy"))) (arm (PTuple (PCon "True") (PList)) () (EApp (EVar "permitIoAsJoin") (EVar "policy"))) (arm (PTuple PWild (PList)) () (EVar "Forbidden")) (arm (PTuple PWild (PVar "written")) () (EMatch (EApp (EVar "allOk") (EApp (EApp (EMethodRef "map") (EApp (EVar "decodeWrittenParam") (EApp (EVar "atomLabelOf") (EVar "a")))) (EVar "written"))) (arm (PCon "Ok" (PVar "pps")) () (EIf (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "a"))) (EApp (EVar "authJoinAll") (EApp (EApp (EMethodRef "map") (EVar "AConst")) (EVar "pps")))) (EVar "Permitted") (EVar "Forbidden"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Malformed") (EVar "m")))))))
(DTypeSig false "permitIoAsJoin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit")))
(DFunDef false "permitIoAsJoin" ((PVar "policy")) (EApp (EVar "firstNotPermitted") (EApp (EApp (EMethodRef "map") (ELam ((PVar "l")) (EApp (EApp (EVar "permitOf") (EApp (EVar "atomOfLabel") (EVar "l"))) (EVar "policy")))) (EVar "hostLabels"))))
(DTypeSig false "firstNotPermitted" (TyFun (TyApp (TyCon "List") (TyCon "Permit")) (TyCon "Permit")))
(DFunDef false "firstNotPermitted" ((PList)) (EVar "Permitted"))
(DFunDef false "firstNotPermitted" ((PCons (PCon "Permitted") (PVar "rest"))) (EApp (EVar "firstNotPermitted") (EVar "rest")))
(DFunDef false "firstNotPermitted" ((PCons (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "notProvenLines" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "notProvenLines" ((PVar "effs") (PVar "policy")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "a")) (EMatch (ETuple (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a"))) (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy"))) (arm (PTuple (PCon "True") (PCon "Forbidden")) () (EMatch (EApp (EApp (EVar "policyEntriesFor") (EVar "a")) (EVar "policy")) (arm (PCons PWild PWild) () (EBlock (DoLet false false (PVar "unresolved") (EApp (EApp (EVar "Atom") (EApp (EVar "atomLabelOf") (EVar "a"))) (EApp (EVar "authJoinAll") (EApp (EApp (EMethodRef "map") (EVar "AVar")) (EApp (EVar "authVars") (EApp (EVar "atomAuth") (EVar "a"))))))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   not proven: ")) (EApp (EMethodRef "display") (EApp (EVar "renderAtom") (EVar "unresolved")))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EVar "unresolvedWhy") (EVar "a")))) (ELit (LString ")\n"))))))) (arm (PList) () (EListLit)))) (arm PWild () (EListLit))))) (EVar "effs")))
(DTypeSig true "unresolvedWhy" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "unresolvedWhy" ((PVar "a")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "authvarDefaultName") (EVar "v"))) (ELit (LString "`"))))) (EApp (EVar "authVars") (EApp (EVar "atomAuth") (EVar "a"))))) (DoExpr (EMatch (EVar "names") (arm (PList (PVar "one")) () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variable ")) (EApp (EMethodRef "display") (EVar "one"))) (ELit (LString "")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variables ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "names")))) (ELit (LString ""))))))))
(DTypeSig false "policyEntriesFor" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "policyEntriesFor" ((PVar "a") (PVar "policy")) (EMatch (EApp (EApp (EVar "entriesUnder") (EApp (EVar "policySpelling") (EApp (EVar "qualifiedKey") (EVar "a")))) (EVar "policy")) (arm (PList) () (EApp (EApp (EVar "entriesUnder") (EApp (EVar "atomLabel") (EVar "a"))) (EVar "policy"))) (arm (PVar "es") () (EVar "es"))))
(DTypeSig false "entriesUnder" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "entriesUnder" ((PVar "key") (PVar "policy")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "fst") (EVar "e")) (EVar "key")))) (EVar "policy"))))
(DTypeSig false "policySpelling" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "policySpelling" ((PVar "k")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "k"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "k")) (ELit (LString "\"")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "k")) (ELit (LString "\"")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "k")) (EVar "k")))))
(DTypeSig true "qualifiedKey" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "qualifiedKey" ((PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString "\"")))) (arm PWild () (EApp (EVar "atomLabel") (EVar "a")))))
(DTypeSig true "allOk" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "allOk" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "allOk" ((PCons (PCon "Err" (PVar "m")) PWild)) (EApp (EVar "Err") (EVar "m")))
(DFunDef false "allOk" ((PCons (PCon "Ok" (PVar "x")) (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "allOk") (EVar "rest"))))
(DTypeAlias true "CallGraph" () (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))
(DTypeAlias true "EffectTable" () (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Atom"))))
(DTypeSig false "collectEVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectEVars" ((PCon "EVar" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EMethodRef" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EDictApp" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "f")) (EApp (EVar "collectEVars") (EVar "x"))))
(DFunDef false "collectEVars" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DFunDef false "collectEVars" ((PCon "ELet" PWild PWild PWild (PVar "v") (PVar "body"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "v")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectBind")) (EVar "binds")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectArm")) (EVar "arms"))))
(DFunDef false "collectEVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "c")) (EApp (EVar "collectEVars") (EVar "t"))) (EApp (EVar "collectEVars") (EVar "f"))))
(DFunDef false "collectEVars" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "ERecordCreate" PWild (PVar "flds"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds")))
(DFunDef false "collectEVars" ((PCon "ERecordUpdate" (PVar "e") (PVar "flds") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "flds"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ESlice" (PVar "a") (PVar "b") (PVar "c") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))) (EApp (EVar "collectEVars") (EVar "c"))))
(DFunDef false "collectEVars" ((PCon "EIndex" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" (PWild) (EListLit))
(DTypeSig false "collectBind" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectBind" ((PCon "LetBind" PWild (PVar "clauses") PWild)) (EApp (EApp (EVar "concatMapCP") (EVar "collectClause")) (EVar "clauses")))
(DTypeSig false "collectClause" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectClause" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DTypeSig false "collectArm" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectArm" ((PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectGuard")) (EVar "guards")) (EApp (EVar "collectEVars") (EVar "body"))))
(DTypeSig false "collectGuard" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectGuard" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectFieldAssign" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectFieldAssign" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectStmt" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "concatMapCP" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapCP" (PWild (PList)) (EListLit))
(DFunDef false "concatMapCP" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapCP") (EVar "f")) (EVar "xs"))))
(DTypeSig false "topName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "topName" ((PCon "DFunDef" PWild (PVar "n") PWild PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DExtern" PWild (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topName") (EVar "d")))
(DFunDef false "topName" (PWild) (EVar "None"))
(DTypeSig false "fnBody" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fnBody" ((PCon "DFunDef" PWild (PVar "n") PWild (PVar "body") PWild)) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "collectEVars") (EVar "body")))))
(DFunDef false "fnBody" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "fnBody") (EVar "d")))
(DFunDef false "fnBody" (PWild) (EVar "None"))
(DTypeSig true "buildCallGraph" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CallGraph")))
(DFunDef false "buildCallGraph" ((PVar "decls")) (EBlock (DoLet false false (PVar "tops") (EApp (EApp (EVar "omFromNames") (EApp (EVar "collectOpts") (EApp (EApp (EMethodRef "map") (EVar "topName")) (EVar "decls")))) (EVar "omEmpty"))) (DoLet false false (PVar "bodies") (EApp (EVar "collectOpts") (EApp (EApp (EMethodRef "map") (EVar "fnBody")) (EVar "decls")))) (DoExpr (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (EApp (EVar "restrictBody") (EVar "tops"))) (EVar "bodies")))) (EVar "omEmpty")))))
(DTypeSig false "restrictBody" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "restrictBody" ((PVar "tops") (PTuple (PVar "n") (PVar "refs"))) (ETuple (EVar "n") (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EVar "r")) (EVar "tops")))) (EVar "refs"))))
(DTypeSig false "collectOpts" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "collectOpts" ((PList)) (EListLit))
(DFunDef false "collectOpts" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "collectOpts") (EVar "rest")))
(DFunDef false "collectOpts" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "collectOpts") (EVar "rest"))))
(DTypeSig true "fnEffectsTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "EffectTable")))
(DFunDef false "fnEffectsTable" ((PVar "schemes")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "effectfulPairs") (EVar "schemes")))) (EVar "omEmpty")))
(DTypeSig false "effectfulPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "effectfulPairs" ((PList)) (EListLit))
(DFunDef false "effectfulPairs" ((PCons (PTuple (PVar "name") (PVar "sch")) (PVar "rest"))) (EMatch (EApp (EVar "callPerformed") (EVar "sch")) (arm (PList) () (EApp (EVar "effectfulPairs") (EVar "rest"))) (arm (PVar "effs") () (EBinOp "::" (ETuple (EVar "name") (EVar "effs")) (EApp (EVar "effectfulPairs") (EVar "rest"))))))
(DTypeSig false "callPerformed" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "callPerformed" ((PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "mono"))) (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "force"))) (EApp (EVar "resultSpineRows") (EVar "mono"))))
(DTypeSig false "resultSpineRows" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "resultSpineRows" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild (PVar "row") (PVar "res")) () (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "row"))) (EApp (EVar "resultSpineRows") (EVar "res")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EVar "effrowLabels") (EVar "row"))) (arm PWild () (EListLit))))
(DTypeSig false "fnHasEffect" (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "fnHasEffect" ((PVar "table") (PVar "name") (PVar "label")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "table")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "effs")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (EVar "label")))) (EVar "effs")))))
(DTypeSig true "viaChain" (TyFun (TyCon "CallGraph") (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "viaChain" ((PVar "callGraph") (PVar "effTable") (PVar "start") (PVar "forbiddenLabel")) (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "start")) (EListLit (EVar "start"))))
(DTypeSig false "traceChain" (TyFun (TyCon "CallGraph") (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "traceChain" ((PVar "callGraph") (PVar "effTable") (PVar "forbiddenLabel") (PVar "fn") (PVar "visited")) (EBlock (DoLet false false (PVar "callees") (EMatch (EApp (EApp (EVar "omLookup") (EVar "fn")) (EVar "callGraph")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EVar "s")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "forbiddenLabel")) (EApp (EVar "sortUniqS") (EVar "callees"))) (arm (PCon "None") () (EListLit (EVar "fn"))) (arm (PCon "Some" (PVar "c")) () (EIf (EApp (EApp (EVar "contains") (EVar "c")) (EVar "visited")) (EListLit (EVar "fn") (EVar "c")) (EBinOp "::" (EVar "fn") (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "c")) (EBinOp "::" (EVar "c") (EVar "visited"))))))))))
(DTypeSig false "firstWithEffect" (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstWithEffect" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstWithEffect" ((PVar "effTable") (PVar "label") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "fnHasEffect") (EVar "effTable")) (EVar "c")) (EVar "label")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "label")) (EVar "rest"))))
